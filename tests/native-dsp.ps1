# PCM evidence using synthetic signals; no audio device or account required.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName WindowsBase, System.Net.Http
$refs = @('System.dll','System.Core.dll', [System.Windows.Threading.Dispatcher].Assembly.Location,
    [System.Net.Http.HttpClient].Assembly.Location,
    [Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location)
foreach ($name in @('NAudio.Core.dll','NAudio.WinMM.dll','NAudio.Wasapi.dll')) {
    $path = Join-Path $root "helper/native-deps/$name"
    [Reflection.Assembly]::LoadFrom($path) | Out-Null
    $refs += $path
}
Add-Type -Path @((Join-Path $root 'helper/NativeDSP.cs'), (Join-Path $root 'helper/EnvironmentDSP.cs'), (Join-Path $PSScriptRoot 'native-dsp-fixtures.cs')) -ReferencedAssemblies $refs
function Check($condition, $message) { if (!$condition) { throw $message } }
function Energy([single[]]$values, [int]$start=0) {
    $sum=0.0; for($i=$start;$i -lt $values.Length;$i++){ $sum += $values[$i]*$values[$i] }
    return $sum
}
function Sine([int]$frequency) {
    $data = New-Object single[] 48000
    for($i=0;$i -lt $data.Length;$i++){ $data[$i]=0.25*[Math]::Sin(2*[Math]::PI*$frequency*$i/48000) }
    return ,$data
}
$dry = Sine 8000
$bypass = [single[]]$dry.Clone()
$dsp = New-Object DangoMusic.EnvironmentDSP
$dsp.Configure($false,$true,$true,$true,1,1)
$dsp.Process($bypass,0,$bypass.Length,1,48000)
for($i=0;$i -lt $dry.Length;$i++){Check ($dry[$i] -eq $bypass[$i]) 'disabled DSP must preserve each sample'}
$water=[single[]]$dry.Clone()
$dsp.Configure($true,$true,$false,$false,0,1);$dsp.Reset()
$dsp.Process($water,0,$water.Length,1,48000)
$waterRatio=(Energy $water 1000)/(Energy $dry 1000)
Check ($waterRatio -lt .001) '450Hz underwater lowpass must attenuate 8kHz'
$indoor=[single[]]$dry.Clone()
$dsp.Configure($true,$false,$false,$true,0,1);$dsp.Reset()
$dsp.Process($indoor,0,$indoor.Length,1,48000)
$indoorRatio=(Energy $indoor 1000)/(Energy $dry 1000)
Check ($indoorRatio -lt .3) 'indoor 5kHz lowpass must attenuate 8kHz'
Check ($indoorRatio -gt $waterRatio*10) 'indoor cutoff must differ from underwater'
$rain=[single[]]$dry.Clone()
$dsp.Configure($true,$false,$false,$false,1,1);$dsp.Reset()
$dsp.Process($rain,0,$rain.Length,1,48000)
$rainRatio=(Energy $rain)/(Energy $dry)
Check ($rainRatio -lt .5 -and $rainRatio -gt .05) 'full rain must soften 8kHz rather than only scale amplitude'
$impulse=New-Object single[] 48000;$impulse[0]=.5
$dsp.Configure($true,$false,$true,$false,0,1);$dsp.Reset()
$dsp.Process($impulse,0,$impulse.Length,1,48000)
Check ((Energy $impulse 1000) -gt .0001) 'Schroeder cave reverb must create a delayed impulse tail'
$noStrength=[single[]]$dry.Clone()
$dsp.Configure($true,$true,$true,$true,1,0);$dsp.Reset()
$dsp.Process($noStrength,0,$noStrength.Length,1,48000)
for($i=0;$i -lt $dry.Length;$i++){Check ($dry[$i] -eq $noStrength[$i]) 'zero strength must bypass all effects'}
# Smooth transitions: first block remains closer to dry than the settled signal.
$dsp.Configure($false,$false,$false,$false,0,1);$dsp.Reset()
$warm=New-Object single[] 480;$dsp.Process($warm,0,480,1,48000)
$dsp.Configure($true,$false,$false,$false,1,1)
$first=New-Object single[] 480;for($i=0;$i -lt 480;$i++){$first[$i]=.25}
$dsp.Process($first,0,480,1,48000)
Check ($first[100] -gt .24 -and $first[100] -lt .25) 'rain transition must smooth instead of jump to 0.8 gain'
Check ([Math]::Abs([DangoMusic.EnvironmentDSP]::NormalizedGain($true,6,.8)-1.225) -lt .00001) 'normalize must respect 0.98/peak headroom'
Check ([DangoMusic.EnvironmentDSP]::NormalizedGain($true,20,0) -eq 2) 'normalize positive gain limit'
Check ([DangoMusic.EnvironmentDSP]::NormalizedGain($true,-40,0) -eq .25) 'normalize negative gain limit'
Check ([DangoMusic.EnvironmentDSP]::NormalizedGain($false,6,.8) -eq 1) 'normalize disabled bypass'
Write-Output ('DSP PCM checks passed: water energy ratio={0:N6}; indoor={1:N4}; rain={2:N4}; cave impulse tail verified; bypass, smoothing and normalization verified.' -f $waterRatio,$indoorRatio,$rainRatio)

[DangoMusic.DSPFixtures]::Run()

