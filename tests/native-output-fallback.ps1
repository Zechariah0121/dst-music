# Initialization policy only: no sound device, network or account is used.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName WindowsBase, System.Net.Http
$refs = @('System.dll','System.Core.dll',[System.Windows.Threading.Dispatcher].Assembly.Location,
    [System.Net.Http.HttpClient].Assembly.Location,
    [Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location)
foreach ($name in @('NAudio.Core.dll','NAudio.WinMM.dll','NAudio.Wasapi.dll')) {
    $path = Join-Path $root "helper/native-deps/$name"
    [Reflection.Assembly]::LoadFrom($path) | Out-Null
    $refs += $path
}
$fixture = @'
using System;
using NAudio.Wave;
public static class NativeOutputFallbackProbe {
    sealed class Feed : IWaveProvider {
        public WaveFormat WaveFormat { get { return new WaveFormat(44100,16,2); } }
        public int Read(byte[] buffer,int offset,int count) { return 0; }
    }
    sealed class Device : IWavePlayer {
        public bool Fail,Disposed; public int Initializations;
        public event EventHandler<StoppedEventArgs> PlaybackStopped {add{} remove{}}
        public PlaybackState PlaybackState {get{return PlaybackState.Stopped;}}
        public WaveFormat OutputWaveFormat {get{return new WaveFormat(44100,16,2);}}
        public float Volume {get;set;}
        public void Init(IWaveProvider source){Initializations++;if(Fail)throw new InvalidOperationException("fixture-only");}
        public void Play(){} public void Pause(){} public void Stop(){}
        public void Dispose(){Disposed=true;}
    }
    static void Check(bool pass,string label){if(!pass)throw new Exception(label);}
    public static void Run(){
        var feed=new Feed();var shared=new Device();var legacy=new Device();int legacyCreates=0;
        var selected=DangoMusic.NativeAudio.InitializeOutput(feed,"auto",()=>shared,()=>{legacyCreates++;return legacy;});
        Check(selected==shared&&shared.Initializations==1&&legacyCreates==0,"auto prefers shared");selected.Dispose();
        shared=new Device{Fail=true};legacy=new Device();legacyCreates=0;
        selected=DangoMusic.NativeAudio.InitializeOutput(feed,"auto",()=>shared,()=>{legacyCreates++;return legacy;});
        Check(selected==legacy&&shared.Disposed&&legacyCreates==1&&legacy.Initializations==1,"failed shared init disposes then falls back exactly once");selected.Dispose();
        legacy=new Device();
        selected=DangoMusic.NativeAudio.InitializeOutput(feed,"auto",()=>{throw new NotSupportedException();},()=>legacy);
        Check(selected==legacy,"constructor failure falls back");selected.Dispose();
        shared=new Device{Fail=true};legacyCreates=0;bool threw=false;
        try{DangoMusic.NativeAudio.InitializeOutput(feed,"wasapi",()=>shared,()=>{legacyCreates++;return new Device();});}catch(InvalidOperationException){threw=true;}
        Check(threw&&shared.Disposed&&legacyCreates==0,"forced shared never silently falls back");
        legacy=new Device();int sharedCreates=0;
        selected=DangoMusic.NativeAudio.InitializeOutput(feed,"waveout",()=>{sharedCreates++;return new Device();},()=>legacy);
        Check(selected==legacy&&sharedCreates==0,"forced legacy never initializes shared");selected.Dispose();
        shared=new Device{Fail=true};legacy=new Device{Fail=true};threw=false;
        try{DangoMusic.NativeAudio.InitializeOutput(feed,"auto",()=>shared,()=>legacy);}catch(InvalidOperationException){threw=true;}
        Check(threw&&shared.Disposed&&legacy.Disposed,"both failures dispose and propagate");
        Console.WriteLine("Output initialization: 6 cases passed; no audio device opened.");
    }
}
'@
$sourcePath = Join-Path ([IO.Path]::GetTempPath()) (([Guid]::NewGuid().ToString('N'))+'.cs')
try {
    [IO.File]::WriteAllText($sourcePath,$fixture)
    Add-Type -Path @((Join-Path $root 'helper/NativeDSP.cs'),(Join-Path $root 'helper/SharedAudioOutput.cs'),(Join-Path $root 'helper/EnvironmentDSP.cs'),$sourcePath) -ReferencedAssemblies $refs
    [NativeOutputFallbackProbe]::Run()
} finally {Remove-Item -LiteralPath $sourcePath -ErrorAction SilentlyContinue}
