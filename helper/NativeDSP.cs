// Environmental DSP ported from Sorihiko/DangoMusic EnvironmentAudio.kt,
// commit ffd88ffc9f4b4af30ef7550eb9781468ab180c31 (GPL-3.0).
// See native-deps/SOURCES.md and DangoMusic.LICENSE.txt.
using System;
using System.Collections.Generic;
using System.IO;
using System.Diagnostics;
using System.Net.Http;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace DangoMusic {
    // Disk-backed decoding prevents network reads from ever stalling waveOut or
    // the control dispatcher. Each in-flight download has its own cancellation.
    public sealed class NativeAudio : IDisposable {
        sealed class Samples : ISampleProvider {
            readonly ISampleProvider source;readonly object gate;
            public readonly EnvironmentDSP DSP=new EnvironmentDSP();
            public volatile float Volume=1,Normalization=1;
            public Samples(ISampleProvider source,object gate){this.source=source;this.gate=gate;}
            public WaveFormat WaveFormat{get{return source.WaveFormat;}}
            public int Read(float[] buffer,int offset,int count){lock(gate){int read=source.Read(buffer,offset,count);float n=Normalization;for(int i=offset;i<offset+read;i++)buffer[i]=Math.Max(-1,Math.Min(1,buffer[i]*n));DSP.Process(buffer,offset,read,WaveFormat.Channels,WaveFormat.SampleRate);float v=Volume;for(int i=offset;i<offset+read;i++)buffer[i]=Math.Max(-1,Math.Min(1,buffer[i]*v));return read;}}
        }
        readonly Dispatcher dispatcher=Dispatcher.CurrentDispatcher;
        readonly object gate=new object();
        readonly CancellationTokenSource cancel=new CancellationTokenSource();
        readonly string cacheDir;
        WaveStream reader;WaveOutEvent output;Samples samples;
        string file;volatile bool disposed,closing;
        bool playWanted,hasStarted,seekPending;double pendingPosition;Task seekTask,openTask;
        TaskCompletionSource<bool> workerStopped;
        double volume=.7,originPosition;
        long originBytes;
        Dictionary<string,object> audio;
        public event EventHandler MediaOpened,MediaEnded,MediaFailed;
        public bool MediaHttpFailed{get;private set;}
        static int cleanedCache;
        static readonly object cleanupGate=new object();
        static readonly List<Task> cleanupTasks=new List<Task>();
        public NativeAudio(string cacheDir){
            this.cacheDir=cacheDir;
            // The worker mutex excludes another owner. Remove orphan spools from
            // an earlier process before the first track, never active downloads.
            if(Interlocked.Exchange(ref cleanedCache,1)==0){
                Directory.CreateDirectory(cacheDir);
                foreach(string path in Directory.GetFiles(cacheDir,"*.audio"))TryDelete(path);
                foreach(string path in Directory.GetFiles(cacheDir,"*.pcm"))TryDelete(path);
            }
        }
        public double Duration{get{return pcm!=null?pcm.Duration:reader==null?0:reader.TotalTime.TotalSeconds;}}
        public double Position{
            get{if(seekPending)return pendingPosition;if(pcm!=null)return output==null?pcm.Position:pcm.PlayedPosition(Math.Max(0,output.GetPosition()-originBytes));if(output==null)return originPosition;return Math.Min(Duration,Math.Max(0,originPosition+(output.GetPosition()-originBytes)/(double)(reader.WaveFormat.SampleRate*reader.WaveFormat.Channels*2)));}
            set{
                pendingPosition=Math.Max(0,Math.Min(Duration,value));
                if(reader==null&&pcm==null){originPosition=value;return;}
                if(seekPending)return;
                if(!hasStarted){ApplySeek();return;}
                seekPending=true;
                var previous=output;output=null;var stoppedSignal=workerStopped.Task;
                // Stop/Play can overlap WaveOutEvent's old refill worker. Join its
                // disposal off the STA, then build a fresh device for the latest seek.
                seekTask=Task.Run(delegate{previous.Stop();stoppedSignal.Wait();previous.Dispose();});
                seekTask.ContinueWith(delegate(Task task){
                    if(task.IsFaulted){var observed=task.Exception;Post(delegate{seekPending=false;Raise(MediaFailed);});return;}
                    Post(delegate{
                        ApplySeek();AttachOutput();seekPending=false;hasStarted=false;
                        if(playWanted)Play();
                    });
                });
            }
        }
        void ApplySeek(){
            lock(gate){
                if(pcm!=null)pcm.Seek(pendingPosition);
                else reader.CurrentTime=TimeSpan.FromSeconds(pendingPosition);
                samples.DSP.Reset();
            }
            originPosition=pendingPosition;
            originBytes=output==null?0:output.GetPosition();
        }
        public double Volume{get{return volume;}set{volume=value;ConfigureAudio(audio);}}
        static double Num(Dictionary<string,object>d,string k,double fallback){object v;return d!=null&&d.TryGetValue(k,out v)?Convert.ToDouble(v):fallback;}
        static bool Bool(Dictionary<string,object>d,string k,bool fallback){object v;return d!=null&&d.TryGetValue(k,out v)&&v is bool?(bool)v:fallback;}
        public void ConfigureAudio(Dictionary<string,object> value){
            audio=value;if(samples==null)return;
            // New protocol carries logical volume to avoid applying normalization
            // twice. Old protocol's desired.volume remains a valid fallback.
            bool nativeGain=audio!=null&&audio.ContainsKey("baseVolume");
            double v=nativeGain?Num(audio,"baseVolume",volume):volume;
            samples.Normalization=(float)(nativeGain?EnvironmentDSP.NormalizedGain(Bool(audio,"normalize",false),Num(audio,"gainDb",0),Num(audio,"peak",0)):1);
            samples.Volume=(float)Math.Max(0,Math.Min(1,v));
            object env;var e=audio!=null&&audio.TryGetValue("env",out env)?env as Dictionary<string,object>:null;
            object region;string regionName=e!=null&&e.TryGetValue("region",out region)?region as string:null;
            samples.DSP.Configure(Bool(e,"enabled",false),regionName,Bool(e,"water",false),Bool(e,"cave",false),Bool(e,"indoor",false),Num(e,"rain",0),Num(e,"strength",1));
        }
        // Only the worker touches network/codec state. The device reads bounded
        // in-memory PCM blocks and never waits for download or decoder work.
        sealed class PcmBuffer : ISampleProvider {
            const int BlockSize=65536, Slots=16;
            const long Limit=256L*1024*1024;
            readonly byte[][] blocks=new byte[Slots][];
            readonly long[] indices=new long[Slots];
            readonly int[] sizes=new int[Slots];
            readonly object sync=new object();
            readonly FileStream writer;
            readonly CancellationToken token;
            long length,cursor,emitted;
            readonly long[] emittedStarts=new long[128],sourceStarts=new long[128];
            readonly int[] realCounts=new int[128];int historyCount;
            volatile bool complete;
            public double Hint;
            readonly WaveFormat pcmFormat;
            public WaveFormat WaveFormat {get;private set;}
            public PcmBuffer(WaveFormat format,double hint,string path,CancellationToken token,Action failure){
                pcmFormat=format;WaveFormat=WaveFormat.CreateIeeeFloatWaveFormat(format.SampleRate,format.Channels);Hint=hint;this.token=token;
                if(format.BitsPerSample!=16)throw new InvalidDataException("PCM format");
                writer=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete,65536,FileOptions.DeleteOnClose);
                var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
                for(int i=0;i<Slots;i++){blocks[i]=new byte[BlockSize];indices[i]=-1;}
                Task.Run(delegate{
                    byte[] scratch=new byte[BlockSize];
                    try{using(input){while(!token.IsCancellationRequested){
                        long start;lock(sync)start=cursor/BlockSize;
                        long available=Interlocked.Read(ref length);
                        for(long index=start;index<start+Slots&&index*BlockSize<available;index++){
                            int slot=(int)(index%Slots),wanted=(int)Math.Min(BlockSize,available-index*BlockSize);
                            lock(sync){if(indices[slot]==index&&sizes[slot]>=wanted)continue;}
                            input.Position=index*BlockSize;int n=input.Read(scratch,0,wanted);
                            lock(sync){Buffer.BlockCopy(scratch,0,blocks[slot],0,n);indices[slot]=index;sizes[slot]=n;}
                        }
                        Thread.Sleep(10);
                    }}}
                    catch(Exception error){if(!token.IsCancellationRequested){Diagnostic("pcm-prefetch",error);failure();}}
                });
            }
            public double Duration {get{return complete?Interlocked.Read(ref length)/(double)pcmFormat.AverageBytesPerSecond:Math.Max(Hint,Interlocked.Read(ref length)/(double)pcmFormat.AverageBytesPerSecond);}}
            public double Position {get{lock(sync)return cursor/(double)pcmFormat.AverageBytesPerSecond;}}
            public void Seek(double seconds){lock(sync){cursor=(long)(Math.Max(0,seconds)*WaveFormat.SampleRate)*pcmFormat.BlockAlign;emitted=0;historyCount=0;}}
            public double PlayedPosition(long deviceBytes){lock(sync){
                long played=deviceBytes/2;
                for(int i=historyCount-1;i>=Math.Max(0,historyCount-128);i--){int slot=i%128;if(played>=emittedStarts[slot])return (sourceStarts[slot]+Math.Min(realCounts[slot],played-emittedStarts[slot]))/(double)(pcmFormat.SampleRate*pcmFormat.Channels);}
                return cursor/(double)pcmFormat.AverageBytesPerSecond;
            }}
            public void Append(byte[] data,int count){
                if(Interlocked.Read(ref length)+count>Limit)throw new InvalidDataException("PCM limit");
                writer.Write(data,0,count);writer.Flush();Interlocked.Add(ref length,count);
            }
            public void Complete(){writer.Dispose();complete=true;}
            public void Abort(){writer.Dispose();}
            public int Read(float[] data,int offset,int count){lock(sync){
                long available=Interlocked.Read(ref length);
                if(complete&&cursor>=available)return 0;
                long sourceStart=cursor/2;int copied=0;
                while(copied<count&&cursor<available){
                    long index=cursor/BlockSize;int slot=(int)(index%Slots),within=(int)(cursor%BlockSize);
                    if(indices[slot]!=index||sizes[slot]<=within)break;
                    int n=Math.Min((count-copied)*2,sizes[slot]-within);
                    n-=n%pcmFormat.BlockAlign;if(n==0)break;
                    for(int i=0;i<n;i+=2)data[offset+copied+i/2]=(short)(blocks[slot][within+i]|(blocks[slot][within+i+1]<<8))/32768f;cursor+=n;copied+=n/2;
                }
                Array.Clear(data,offset+copied,count-copied);
                int returned=complete&&cursor>=available?copied:count;
                int historySlot=historyCount++%128;emittedStarts[historySlot]=emitted;sourceStarts[historySlot]=sourceStart;realCounts[historySlot]=copied;emitted+=returned;
                return returned;
            }}
        }
        // A bounded rewindable download spool supports the MP3 frame parser's
        // Position/Seek contract while every potentially blocking read stays here.
        sealed class Download : Stream {
            readonly Stream source;readonly FileStream cache;readonly CancellationToken token;
            readonly long declared;long stored,position;
            readonly Timer idle;
            public Download(Stream source,string path,long declared,CancellationToken token){this.source=source;this.declared=declared;this.token=token;cache=new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read);idle=new Timer(delegate{Console.Error.WriteLine("native_audio network_idle_timeout=1 idleMs=60000");try{source.Dispose();}catch{}},null,Timeout.Infinite,Timeout.Infinite);}
            public override int Read(byte[] buffer,int offset,int count){
                int total=0;while(total<count){int n=ReadPart(buffer,offset+total,count-total);if(n==0)break;total+=n;}return total;
            }
            int ReadPart(byte[] buffer,int offset,int count){
                token.ThrowIfCancellationRequested();
                if(position<stored){cache.Position=position;int n=cache.Read(buffer,offset,(int)Math.Min(count,stored-position));position+=n;return n;}
                int read;
                idle.Change(60000,Timeout.Infinite);
                try{read=source.ReadAsync(buffer,offset,count,token).GetAwaiter().GetResult();}
                finally{idle.Change(Timeout.Infinite,Timeout.Infinite);}
                if(stored+read>256L*1024*1024)throw new InvalidDataException("Download limit");
                cache.Position=stored;cache.Write(buffer,offset,read);stored+=read;position+=read;return read;
            }
            public void Finish(){byte[] data=new byte[65536];position=stored;while(Read(data,0,data.Length)>0){}cache.Flush();}
            public override long Seek(long offset,SeekOrigin origin){long next=origin==SeekOrigin.Begin?offset:origin==SeekOrigin.Current?position+offset:Length+offset;if(next<0||next>stored)throw new IOException();position=next;return next;}
            public override long Position{get{return position;}set{Seek(value,SeekOrigin.Begin);}}
            public override long Length{get{return declared>=0?declared:stored;}}
            public override bool CanRead{get{return true;}}public override bool CanSeek{get{return true;}}public override bool CanWrite{get{return false;}}
            public override void Flush(){cache.Flush();}public override void SetLength(long value){throw new NotSupportedException();}public override void Write(byte[] b,int o,int c){throw new NotSupportedException();}
            protected override void Dispose(bool disposing){if(disposing){idle.Dispose();cache.Dispose();}base.Dispose(disposing);}
        }
        PcmBuffer pcm;
        void Publish(ISampleProvider source){
            if(disposed)return;
            samples=new Samples(source,gate);ConfigureAudio(audio);samples.DSP.Reset();
            AttachOutput();Raise(MediaOpened);
        }
        void AttachOutput(){
            WaveOutEvent current;
            // WaveOutEvent otherwise captures the STA synchronization context for
            // PlaybackStopped. Its completion signal must survive dispatcher exit.
            var context=SynchronizationContext.Current;
            try{
                SynchronizationContext.SetSynchronizationContext(null);
                current=new WaveOutEvent{DesiredLatency=60,NumberOfBuffers=3};
            }finally{SynchronizationContext.SetSynchronizationContext(context);}
            output=current;
            var stoppedSignal=new TaskCompletionSource<bool>();workerStopped=stoppedSignal;
            current.PlaybackStopped+=delegate(object sender,StoppedEventArgs args){
                stoppedSignal.TrySetResult(true);
                bool suppress=closing;
                if(dispatcher.HasShutdownStarted)return;
                dispatcher.BeginInvoke(new Action(delegate{
                    if(disposed||suppress||output!=current)return;
                    if(args.Exception!=null){Diagnostic("device",args.Exception);Raise(MediaFailed);}
                    else if(current.PlaybackState==PlaybackState.Stopped&&Position>=Duration-.15)Raise(MediaEnded);
                }));
            };
            current.Init(new SampleToWaveProvider16(samples));originBytes=current.GetPosition();
        }
        void Post(Action action){
            if(disposed||dispatcher.HasShutdownStarted)return;
            dispatcher.BeginInvoke(new Action(delegate{
                if(disposed)return;
                try{action();}catch(Exception error){Diagnostic("dispatcher",error);Raise(MediaFailed);}
            }));
        }
        public void Open(Uri url,double durationHint){
            // Duration in the bridge is seconds, matching desired.position.
            openTask=Task.Run(async delegate {
                string path=Path.Combine(cacheDir,Guid.NewGuid().ToString("N")+".audio");
                string stage="response";int frames=0;
                try{
                    Directory.CreateDirectory(cacheDir);
                    using(var http=new HttpClient(new HttpClientHandler{UseProxy=false})){
                        http.Timeout=Timeout.InfiniteTimeSpan;
                        using(var headerDeadline=CancellationTokenSource.CreateLinkedTokenSource(cancel.Token)){
                        headerDeadline.CancelAfter(TimeSpan.FromSeconds(30));
                        using(var response=await http.GetAsync(url,HttpCompletionOption.ResponseHeadersRead,headerDeadline.Token).ConfigureAwait(false)){
                            headerDeadline.CancelAfter(Timeout.Infinite);
                            if(!response.IsSuccessStatusCode){
                                if(!cancel.IsCancellationRequested)Console.Error.WriteLine("native_audio stage=response httpStatus="+(int)response.StatusCode);
                                Post(delegate{MediaHttpFailed=true;Raise(MediaFailed);});
                                return;
                            }
                            using(var input=await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                            using(var registration=cancel.Token.Register(delegate{input.Dispose();}))
                            using(var download=new Download(input,path,response.Content.Headers.ContentLength??-1,cancel.Token)){
                                stage="sniff";
                                byte[] header=new byte[10];int got=0,n;
                                while(got<header.Length&&(n=download.Read(header,got,header.Length-got))>0)got+=n;
                                download.Position=0;
                                bool mp3=got>=3&&((header[0]==73&&header[1]==68&&header[2]==51)||(header[0]==255&&(header[1]&224)==224));
                                if(mp3){
                                    if(header[0]==73){
                                        int tag=((header[6]&127)<<21)|((header[7]&127)<<14)|((header[8]&127)<<7)|(header[9]&127);
                                        if(tag>16*1024*1024)throw new InvalidDataException("ID3 limit");
                                        byte[] skip=new byte[65536];long remaining=10L+tag+((header[5]&16)!=0?10:0);
                                        while(remaining>0){n=download.Read(skip,0,(int)Math.Min(skip.Length,remaining));if(n==0)throw new EndOfStreamException();remaining-=n;}
                                    }
                                    stage="first-frame";
                                    Mp3Frame first=Mp3Frame.LoadFromStream(download);
                                    if(first==null)throw new InvalidDataException();
                                    int channels=first.ChannelMode==ChannelMode.Mono?1:2;
                                    stage="decoder-init";
                                    using(var decoder=new AcmMp3FrameDecompressor(new Mp3WaveFormat(first.SampleRate,channels,first.FrameLength,first.BitRate))){
                                        var buffer=new PcmBuffer(decoder.OutputFormat,durationHint>0?durationHint:(response.Content.Headers.ContentLength??0)*8.0/first.BitRate,path+".pcm",cancel.Token,delegate{Post(delegate{Raise(MediaFailed);});});
                                        try {
                                        byte[] decoded=new byte[65536];Mp3Frame frame=first;bool published=false;
                                        do{cancel.Token.ThrowIfCancellationRequested();stage="decode";n=decoder.DecompressFrame(frame,decoded,0);stage="pcm-append";buffer.Append(decoded,n);frames++;
                                            if(!published&&n>0){published=true;Post(delegate{pcm=buffer;Publish(buffer);});}
                                        stage="next-frame";
                                        }while((frame=Mp3Frame.LoadFromStream(download))!=null);
                                        buffer.Complete();
                                        } finally {buffer.Abort();}
                                    }
                                    return;
                                }
                                stage="fallback-download";download.Finish();
                            }
                        }
                    }
                    }
                    cancel.Token.ThrowIfCancellationRequested();
                    stage="fallback-decode";
                    var decodedReader=new MediaFoundationReader(path);
                    if(disposed||dispatcher.HasShutdownStarted){decodedReader.Dispose();return;}
                    string retainedPath=path;
                    Action abandon=delegate{decodedReader.Dispose();TryDelete(retainedPath);};
                    if(disposed||dispatcher.HasShutdownStarted){abandon();return;}
                    var pending=dispatcher.BeginInvoke(new Action(delegate{
                        if(disposed){abandon();return;}
                        file=retainedPath;reader=decodedReader;
                        try{Publish(reader.ToSampleProvider());}catch(Exception error){Diagnostic("fallback-publish",error);Raise(MediaFailed);}
                    }));
                    pending.Aborted+=delegate{abandon();};
                    if(pending.Status==DispatcherOperationStatus.Aborted)abandon();
                    path=null; // reader owns the retained fallback file until Close.
                }catch(Exception error){if(!cancel.IsCancellationRequested)Diagnostic(stage+" frames="+frames,error);cancel.Cancel();Post(delegate{Raise(MediaFailed);});}
                finally{TryDelete(path);}
            });
        }
        // Exception messages can contain request URLs. Log only types, numeric
        // HRESULT and reflected method names, with no messages or parameter data.
        static void Diagnostic(string stage,Exception error){
            for(int depth=0;error!=null&&depth<3;depth++,error=error.InnerException){
                var methods=new List<string>();
                var frames=new StackTrace(error,false).GetFrames();
                if(frames!=null)foreach(var frame in frames){
                    var method=frame.GetMethod();
                    if(method!=null)methods.Add((method.DeclaringType==null?"":method.DeclaringType.FullName+".")+method.Name);
                }
                Console.Error.WriteLine("native_audio stage="+stage+" depth="+depth+" type="+error.GetType().FullName+" hresult="+error.HResult.ToString("X8")+(error is WebException?" webStatus="+((WebException)error).Status.ToString():"")+" stack="+String.Join("|",methods.ToArray()));
            }
        }
        void Raise(EventHandler callback){if(callback!=null)callback(this,EventArgs.Empty);}
        public void Play(){playWanted=true;if(output!=null&&!seekPending){hasStarted=true;output.Play();}}
        public void Pause(){playWanted=false;if(output!=null)output.Pause();}
        public void Stop(){playWanted=false;if(output!=null){closing=true;output.Stop();closing=false;}}
        public void Close(){Dispose();}
        static void TryDelete(string path){try{if(path!=null)File.Delete(path);}catch{}}
        public void Dispose(){
            if(disposed)return;disposed=true;cancel.Cancel();
            var previous=output;output=null;var pending=seekTask;
            var stoppedSignal=workerStopped;bool started=hasStarted;var opening=openTask;
            var cleanup=Task.Run(delegate{
                if(pending!=null){try{pending.Wait();}catch{}}
                if(previous!=null){previous.Stop();if(started&&stoppedSignal!=null)stoppedSignal.Task.Wait();previous.Dispose();}
                if(opening!=null){try{opening.Wait();}catch{}}
                if(reader!=null)reader.Dispose();TryDelete(file);
            });
            lock(cleanupGate){cleanupTasks.RemoveAll(task=>task.IsCompleted);cleanupTasks.Add(cleanup);}
        }
        internal static void WaitForCleanup(){
            Task[] pending;lock(cleanupGate)pending=cleanupTasks.ToArray();
            try{Task.WaitAll(pending,TimeSpan.FromSeconds(3));}catch{}
        }
    }
}
