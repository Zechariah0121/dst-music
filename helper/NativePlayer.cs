using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Threading;

namespace DangoMusic {
    // All playback control happens on this STA dispatcher. Network tasks only
    // return JSON; they never block, or dispatch synchronously onto, the audio STA.
    public sealed class NativePlayer : IDisposable {
        sealed class Reply { public int Status; public Dictionary<string, object> Body; }
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        readonly HttpClient http;
        readonly Dispatcher dispatcher;
        readonly DispatcherTimer timer;
        readonly string clientId = "native_" + Guid.NewGuid().ToString("N");
        readonly Uri origin;
        readonly string cacheDir;
        readonly int unavailableSeconds;
        readonly Process parent;
        readonly Stopwatch clock = Stopwatch.StartNew();
        NativeAudio media;
        Task<Reply> stateTask, reportTask;
        Task<bool?> gameProbeTask;
        bool? gameRunning;
        double nextGameProbe;
        bool claimed, opened, failed, ended, endedAcknowledged, requestedPlaying, actualPlaying, stopped;
        long revision = -1, seekRevision = -1, generation, audioRevision = -1;
        string trackKey, appliedState;
        double targetPosition, targetVolume = 0.7, lastSuccess, nextState, nextReport;
        bool reportHadEnded;
        long reportRevision;
        int exitCode;

        NativePlayer(Dictionary<string, object> config, string stateDir, int parentId, int timeout) {
            if (Text(config, "host") != "127.0.0.1") throw new InvalidDataException();
            int port = Convert.ToInt32(config["port"], CultureInfo.InvariantCulture);
            if (port < 1 || port > 65535) throw new InvalidDataException();
            string token = Text(config, "token");
            if (!System.Text.RegularExpressions.Regex.IsMatch(token, "^[a-zA-Z0-9_-]{24,128}$")) throw new InvalidDataException();
            origin = new Uri("http://127.0.0.1:" + port + "/");
            cacheDir = Path.Combine(stateDir,"cache","native");
            http = new HttpClient(new HttpClientHandler { UseProxy = false });
            http.Timeout = TimeSpan.FromSeconds(12);
            http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            unavailableSeconds = Math.Max(3, timeout);
            if (parentId > 0) parent = Process.GetProcessById(parentId);
            dispatcher = Dispatcher.CurrentDispatcher;
            timer = new DispatcherTimer(TimeSpan.FromMilliseconds(20), DispatcherPriority.Normal, Tick, dispatcher);
        }

        public static int Run(string stateDir, int parentId, int timeout) {
            var parser = new JavaScriptSerializer();
            var config = parser.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(stateDir, "bridge.json")));
            // Same server endpoint must have only one local native worker. Never
            // force another owner's lease, even when the launcher is run twice.
            string name = "Local\\DangoMusicNative_" + Convert.ToInt32(config["port"], CultureInfo.InvariantCulture);
            bool acquired;
            using (var mutex = new Mutex(true, name, out acquired)) {
                if (!acquired) return 3;
                try {
                    using (var worker = new NativePlayer(config, stateDir, parentId, timeout)) {
                        Dispatcher.Run();
                        return worker.exitCode;
                    }
                } finally { mutex.ReleaseMutex(); }
            }
        }

        static string Text(Dictionary<string, object> value, string key) {
            object result; return value.TryGetValue(key, out result) && result != null ? Convert.ToString(result, CultureInfo.InvariantCulture) : "";
        }
        static double Number(Dictionary<string, object> value, string key) {
            object result; double number;
            return value.TryGetValue(key, out result) && double.TryParse(Convert.ToString(result, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out number) && !double.IsNaN(number) && !double.IsInfinity(number) ? number : 0;
        }
        static bool Flag(Dictionary<string, object> value, string key) { object result; return value.TryGetValue(key, out result) && result is bool && (bool)result; }
        double Now { get { return clock.Elapsed.TotalSeconds; } }
        async Task<Reply> Request(string path, object body) {
            using (var request = new HttpRequestMessage(body == null ? HttpMethod.Get : HttpMethod.Post, new Uri(origin, path))) {
                if (body != null) request.Content = new StringContent(new JavaScriptSerializer().Serialize(body), Encoding.UTF8, "application/json");
                using (var response = await http.SendAsync(request).ConfigureAwait(false)) {
                    string text = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    return new Reply { Status = (int)response.StatusCode, Body = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(text) };
                }
            }
        }

        bool Accept(Task<Reply> task, out Reply reply) {
            reply = null;
            if (task.IsCanceled || task.IsFaulted) { var observed = task.Exception; return false; }
            reply = task.Result; // Only called for an already completed task.
            if (reply.Status == 401 || reply.Status == 403) { Stop(2); return false; }
            if (reply.Status == 409) { Stop(3); return false; }
            if (reply.Status != 200 || reply.Body == null || !Flag(reply.Body, "ok")) return false;
            lastSuccess = Now;
            return true;
        }
        void Tick(object sender, EventArgs args) {
            try {
                if (stopped) return;
                if ((parent != null && parent.HasExited) || Now - lastSuccess > unavailableSeconds) { Stop(0); return; }
                // Process enumeration runs at most once per second, off the
                // audio dispatcher, with only one outstanding probe.
                if (gameProbeTask != null && gameProbeTask.IsCompleted) {
                    if (gameProbeTask.IsCanceled || gameProbeTask.IsFaulted) { var observed = gameProbeTask.Exception; gameRunning = null; }
                    else gameRunning = gameProbeTask.Result;
                    gameProbeTask = null;
                }
                if (gameProbeTask == null && Now >= nextGameProbe) {
                    nextGameProbe = Now + 1;
                    gameProbeTask = Task.Run(() => GameProcessMonitor.IsClientRunning());
                }
                if (stateTask != null && stateTask.IsCompleted) {
                    Reply reply;
                    bool wasClaimed = claimed;
                    if (Accept(stateTask, out reply)) {
                        if (!wasClaimed) claimed = true;
                        else {
                            audioRevision = reply.Body.ContainsKey("audioRevision") ? (long)Number(reply.Body, "audioRevision") : -1;
                            var desired = (Dictionary<string, object>)reply.Body["desired"];
                            string state = json.Serialize(desired);
                            if (state != appliedState) { Apply(desired); appliedState = state; nextReport = 0; }
                        }
                    }
                    stateTask = null;
                    nextState = wasClaimed && audioRevision < 0 ? Now + 0.12 : Now;
                }
                if (reportTask != null && reportTask.IsCompleted) {
                    Reply reply;
                    if (Accept(reportTask, out reply) && reportHadEnded && ended && reportRevision == revision) endedAcknowledged = true;
                    reportTask = null;
                }
                if (stopped) return;
                if (stateTask == null && Now >= nextState) {
                    nextState = Now + 0.12;
                    stateTask = claimed ? Request("/api/player/state?clientId=" + clientId + (audioRevision >= 0 ? "&after=" + audioRevision + "&wait=8000" : ""), null) : Request("/api/player/claim", new { clientId = clientId });
                }
                if (claimed && revision >= 0 && reportTask == null && Now >= nextReport) {
                    nextReport = Now + 0.35;
                    reportHadEnded = ended && !endedAcknowledged;
                    reportRevision = revision;
                    double duration = opened ? media.Duration : 0;
                    double position = opened ? media.Position : targetPosition;
                    var report = new Dictionary<string, object> {
                        {"clientId", clientId}, {"revision", revision}, {"position", Math.Max(0, position)},
                        {"duration", Math.Max(0, duration)}, {"playing", actualPlaying && !failed && !ended && media!=null && media.IsPlaying},
                        {"error", failed ? (media.MediaHttpFailed ? "Native media HTTP failed" : "Native audio playback failed") : null},
                        {"ended", reportHadEnded}
                    };
                    if (gameRunning.HasValue) report["gameRunning"] = gameRunning.Value;
                    reportTask = Request("/api/player/report", report);
                }
            } catch { Stop(1); }
        }

        void Apply(Dictionary<string, object> desired) {
            long newRevision = (long)Number(desired, "revision");
            if (newRevision < revision) return;
            long newSeek = (long)Number(desired, "seekRevision");
            object track;
            string key = desired.TryGetValue("track", out track) && track is Dictionary<string, object> ? Text((Dictionary<string, object>)track, "id") : "";
            string path = Text(desired, "mediaUrl");
            if (key.Length > 0 && (!path.StartsWith("/api/media?", StringComparison.Ordinal) || path.Contains("\\") || path.Contains("\r") || path.Contains("\n"))) throw new InvalidDataException();
            bool seek = newSeek != seekRevision;
            bool replace = key != trackKey || ((ended || failed) && seek);
            revision = newRevision;
            requestedPlaying = Flag(desired, "playing");
            targetVolume = Math.Max(0, Math.Min(1, Number(desired, "volume")));
            if (seek || replace) targetPosition = Math.Max(0, Number(desired, "position"));
            seekRevision = newSeek;
            if (replace) {
                CloseMedia(); trackKey = key;
                failed = ended = endedAcknowledged = opened = actualPlaying = false;
                if (key.Length == 0) return;
                var current = new NativeAudio(cacheDir);
                media = current;
                long version = ++generation;
                current.MediaOpened += delegate {
                    if (generation != version || stopped) return;
                    opened = true;
                    current.Position = targetPosition;
                    SetPlayback();
                };
                current.MediaEnded += delegate {
                    if (generation != version || stopped) return;
                    ended = true; actualPlaying = false; nextReport = 0;
                };
                current.MediaFailed += delegate {
                    if (generation != version || stopped) return;
                    failed = true; actualPlaying = false; current.Stop(); nextReport = 0;
                };
                current.PlaybackChanged += delegate {if(generation==version&&!stopped)nextReport=0;};
                current.Volume = targetVolume;
                object settings;
                current.ConfigureAudio(desired.TryGetValue("audio",out settings)?settings as Dictionary<string,object>:null);
                current.Open(new Uri(origin, path), track is Dictionary<string, object> ? Number((Dictionary<string, object>)track, "duration") : 0);
                // NativeAudio.Open prepares asynchronously; MediaOpened applies
                // the latest desired seek/play state, including changes mid-load.
            } else if (media != null) {
                object settings;
                media.ConfigureAudio(desired.TryGetValue("audio",out settings)?settings as Dictionary<string,object>:null);
                if (seek && opened) { media.Position = targetPosition; ended = endedAcknowledged = false; }
                SetPlayback();
            }
        }
        void SetPlayback() {
            if (media == null) return;
            media.Volume = targetVolume;
            if (!opened || failed || ended) return;
            if (requestedPlaying) media.Play(); else media.Pause();
            actualPlaying = requestedPlaying;
        }
        void CloseMedia() {
            generation++;
            if (media != null) { media.Stop(); media.Close(); media = null; }
        }
        void Stop(int code) {
            if (stopped) return;
            stopped = true; exitCode = code; timer.Stop(); CloseMedia();
            dispatcher.BeginInvokeShutdown(DispatcherPriority.Normal);
        }
        public void Dispose() { timer.Stop(); CloseMedia(); NativeAudio.WaitForCleanup(); http.Dispose(); if (parent != null) parent.Dispose(); }
    }
}
