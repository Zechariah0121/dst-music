# Bounded progressive PCM cache probe. No sound device, network or account.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName WindowsBase,System.Net.Http
$refs=@('System.dll','System.Core.dll',[System.Windows.Threading.Dispatcher].Assembly.Location,[System.Net.Http.HttpClient].Assembly.Location,[Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location)
foreach($name in @('NAudio.Core.dll','NAudio.WinMM.dll','NAudio.Wasapi.dll')){$path=Join-Path $root "helper/native-deps/$name";[Reflection.Assembly]::LoadFrom($path)|Out-Null;$refs+=$path}
$probe=@'
using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Threading;
using NAudio.Wave;
public static class NativeBufferProbe {
    public static string Run() {
        var type=typeof(DangoMusic.NativeAudio).GetNestedType("PcmBuffer",BindingFlags.NonPublic);
        var path=Path.Combine(Path.GetTempPath(),Guid.NewGuid().ToString("N")+".pcm");
        var cancel=new CancellationTokenSource();
        long baseline=GC.GetTotalMemory(true);
        object buffer=Activator.CreateInstance(type,new object[]{new WaveFormat(48000,16,2),180.0,path,cancel.Token,new Action(delegate{throw new Exception("Read-ahead failure");})});
        var append=type.GetMethod("Append");
        byte[] block=new byte[65536];
        for(int i=0;i<528;i++)append.Invoke(buffer,new object[]{block,block.Length});
        type.GetMethod("Complete").Invoke(buffer,null);
        Thread.Sleep(50);
        long bytes=new FileInfo(path).Length,managed=GC.GetTotalMemory(true)-baseline;
        if(managed>3*1024*1024)throw new Exception("PCM RAM grows beyond fixed cache allowance");
        var provider=(ISampleProvider)buffer;
        float[] samples=new float[1920];var clock=new Stopwatch();double max=0;
        for(int i=0;i<10000;i++){
            clock.Restart();provider.Read(samples,0,samples.Length);clock.Stop();
            max=Math.Max(max,clock.Elapsed.TotalMilliseconds);
            if(i%100==0)Thread.Sleep(1);
        }
        type.GetMethod("Seek").Invoke(buffer,new object[]{170.0});
        Thread.Sleep(50);provider.Read(samples,0,samples.Length);
        double position=(double)type.GetProperty("Position").GetValue(buffer,null);
        if(position<170||position>170.1)throw new Exception("Future seek cursor is incorrect");
        cancel.Cancel();Thread.Sleep(100);
        if(File.Exists(path))throw new Exception("PCM spool did not release on cancellation");
        cancel.Dispose();
        return "diskBytes="+bytes+" managedDeltaBytes="+managed+" callbackMaxMs="+max.ToString("F3")+" calls=10000";
    }
}
'@
$fixture=Join-Path ([IO.Path]::GetTempPath()) (([Guid]::NewGuid().ToString('N'))+'.cs')
try {
    [IO.File]::WriteAllText($fixture,$probe)
    Add-Type -Path @((Join-Path $root 'helper/NativeDSP.cs'),(Join-Path $root 'helper/EnvironmentDSP.cs'),$fixture) -ReferencedAssemblies $refs
    [NativeBufferProbe]::Run()
} finally {Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue}
