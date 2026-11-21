param(
    [string]$StateDir = (Join-Path $PSScriptRoot '..\.state'),
    [int]$ParentProcessId = 0,
    [int]$MaxUnavailableSeconds = 15
)

$ErrorActionPreference = 'Stop'
try {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Native player requires powershell.exe -STA.'
    }
    Add-Type -AssemblyName PresentationCore, WindowsBase, System.Net.Http, System.Web.Extensions
    $depDir = Join-Path $PSScriptRoot 'native-deps'
    $audioRefs = @('NAudio.Core.dll','NAudio.WinMM.dll','NAudio.Wasapi.dll') | ForEach-Object {
        $depPath = Join-Path $depDir $_
        [Reflection.Assembly]::LoadFrom($depPath) | Out-Null
        $depPath
    }
    $references = @(
        'System.dll', 'System.Core.dll',
        [System.Windows.Media.MediaPlayer].Assembly.Location,
        [System.Windows.Threading.Dispatcher].Assembly.Location,
        [System.Net.Http.HttpClient].Assembly.Location,
        [System.Web.Script.Serialization.JavaScriptSerializer].Assembly.Location,
        [Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location
    ) + $audioRefs
    Add-Type -Path @((Join-Path $PSScriptRoot 'NativePlayer.cs'),(Join-Path $PSScriptRoot 'NativeDSP.cs'),(Join-Path $PSScriptRoot 'SharedAudioOutput.cs'),(Join-Path $PSScriptRoot 'EnvironmentDSP.cs'),(Join-Path $PSScriptRoot 'GameProcessMonitor.cs')) -ReferencedAssemblies $references
    $result = [DangoMusic.NativePlayer]::Run([IO.Path]::GetFullPath($StateDir), $ParentProcessId, $MaxUnavailableSeconds)
    exit $result
} catch {
    # Never print exceptions: request URIs and config may contain the local token.
    [Console]::Error.WriteLine('Native audio worker failed to initialize. Check Windows audio/runtime availability and local bridge configuration.')
    exit 1
}
