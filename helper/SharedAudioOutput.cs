using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace DangoMusic {
    internal sealed class SharedAudioOutput : IWavePlayer, IWavePosition {
        readonly Thread ownerThread;
        readonly Dispatcher owner;
        readonly TaskCompletionSource<bool> workerEnded = new TaskCompletionSource<bool>();
        WasapiOut player;
        DispatcherTimer clockTimer;
        bool started;
        int disposing, stoppedReported, state;
        long position;
        volatile WaveFormat outputFormat;

        public SharedAudioOutput() {
            var ready = new TaskCompletionSource<Dispatcher>();
            ownerThread = new Thread(delegate() {
                try { ready.SetResult(Dispatcher.CurrentDispatcher); }
                catch (Exception error) { ready.TrySetException(error); return; }
                Dispatcher.Run();
            }) { IsBackground = true, Name = "DangoMusic WASAPI" };
            ownerThread.SetApartmentState(ApartmentState.STA);
            ownerThread.Start();
            owner = ready.Task.GetAwaiter().GetResult();
        }

        public event EventHandler<StoppedEventArgs> PlaybackStopped;
        public PlaybackState PlaybackState { get { return (PlaybackState)Volatile.Read(ref state); } }
        public WaveFormat OutputWaveFormat { get { return outputFormat; } }
        public long GetPosition() { return Interlocked.Read(ref position); }

        // NativeAudio applies gain in its sample provider. Access to the WASAPI
        // endpoint volume is exposed only through the IWavePlayer property.
        public float Volume {
            get { return owner.Invoke(() => player.Volume); }
            set { owner.Invoke(new Action(delegate { player.Volume = value; })); }
        }

        public void Init(IWaveProvider provider) {
            owner.Invoke(new Action(delegate {
                // Cleanup waits for the actual render worker notification. Delivery
                // must remain independent of both STA dispatchers.
                var context = SynchronizationContext.Current;
                try {
                    SynchronizationContext.SetSynchronizationContext(null);
                    player = new WasapiOut(AudioClientShareMode.Shared, true, 60);
                } finally {
                    SynchronizationContext.SetSynchronizationContext(context);
                }
                player.PlaybackStopped += OnPlaybackStopped;
                player.Init(provider);
                outputFormat = player.OutputWaveFormat;
                clockTimer = new DispatcherTimer(DispatcherPriority.Normal, owner) {
                    Interval = TimeSpan.FromMilliseconds(10)
                };
                clockTimer.Tick += SamplePosition;
            }));
        }

        public void Play() {
            owner.Invoke(new Action(delegate {
                if (started) {
                    if (Interlocked.CompareExchange(ref state, (int)PlaybackState.Playing,
                            (int)PlaybackState.Paused) == (int)PlaybackState.Paused) player.Play();
                    return;
                }
                Volatile.Write(ref state, (int)PlaybackState.Playing);
                try {
                    player.Play();
                    started = true;
                    clockTimer.Start();
                } catch {
                    if (!started) Volatile.Write(ref state, (int)PlaybackState.Stopped);
                    throw;
                }
            }));
        }

        public void Pause() {
            owner.Invoke(new Action(delegate {
                if (Interlocked.CompareExchange(ref state, (int)PlaybackState.Paused,
                        (int)PlaybackState.Playing) == (int)PlaybackState.Playing) player.Pause();
            }));
        }

        void SamplePosition(object sender, EventArgs args) {
            if (PlaybackState == PlaybackState.Stopped) {
                clockTimer.Stop();
                return;
            }
            try {
                // WasapiOut returns bytes in OutputWaveFormat and resets to zero
                // before PlaybackStopped. Retain the last sampled device position.
                long current = player.GetPosition();
                if (current > GetPosition()) Interlocked.Exchange(ref position, current);
            } catch (Exception error) {
                clockTimer.Stop();
                ReportStopped(new StoppedEventArgs(error));
            }
        }

        void OnPlaybackStopped(object sender, StoppedEventArgs args) {
            // A zero-length stream can exit without updating WasapiOut.PlaybackState.
            Volatile.Write(ref state, (int)PlaybackState.Stopped);
            workerEnded.TrySetResult(true);
            ReportStopped(args);
        }

        void ReportStopped(StoppedEventArgs args) {
            Volatile.Write(ref state, (int)PlaybackState.Stopped);
            if (Interlocked.Exchange(ref stoppedReported, 1) == 0) {
                var handler = PlaybackStopped;
                if (handler != null) handler(this, args);
            }
        }

        public void Stop() {
            if (Volatile.Read(ref disposing) != 0) return;
            try { owner.Invoke(new Action(StopCore)); }
            catch (OperationCanceledException) {
                if (Volatile.Read(ref disposing) == 0) throw;
            }
        }

        void StopCore() {
            if (clockTimer != null) clockTimer.Stop();
            if (player == null) return;
            player.Stop();
            // WasapiOut may already say Stopped while its worker is still in Reset.
            if (started) workerEnded.Task.GetAwaiter().GetResult();
            Volatile.Write(ref state, (int)PlaybackState.Stopped);
        }

        public void Dispose() {
            bool onOwner = owner.CheckAccess();
            try {
                if (Interlocked.Exchange(ref disposing, 1) == 0) {
                    if (onOwner) DisposeCore();
                    else owner.Invoke(new Action(DisposeCore));
                }
            } finally {
                if (!onOwner) ownerThread.Join();
            }
        }

        void DisposeCore() {
            try {
                StopCore();
            } finally {
                try {
                    if (player != null) {
                        player.PlaybackStopped -= OnPlaybackStopped;
                        player.Dispose();
                    }
                } finally {
                    owner.BeginInvokeShutdown(DispatcherPriority.Send);
                }
            }
        }
    }
}
