param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime-Paths.ps1')
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) { throw '请使用 Windows PowerShell 5.1 运行检查。' }
$runtime = Get-MusicRuntime
Add-Type -AssemblyName PresentationCore, WindowsBase, System.Net.Http, System.Web.Extensions
[Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51') | Out-Null
foreach ($name in @('NAudio.Core.dll','NAudio.WinMM.dll','NAudio.Wasapi.dll')) {
    [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot ('helper/native-deps/' + $name))) | Out-Null
}
Write-Output '环境检查通过，包内 Node、Python/Pillow 和 Windows .NET 依赖可加载。未启动播放器。'
