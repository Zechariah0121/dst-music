param([string]$StateDir, [switch]$Wait)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime-Paths.ps1')
if (-not $StateDir) { $StateDir = Join-Path $PSScriptRoot '.state' }
$recordPath = Join-Path ([IO.Path]::GetFullPath($StateDir)) 'process.json'
Assert-MusicSafePath $recordPath
if (-not (Test-Path -LiteralPath $recordPath)) { Write-Output '没有本项目启动器记录的后台进程。'; return }
$record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
$musicProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$record.pid)"
if (-not $musicProcess) { Write-Output '后台播放器已经关闭。'; return }
$expectedScript = Join-Path $PSScriptRoot 'helper/server.mjs'
if (-not (Test-MusicProcess $record $expectedScript)) {
    throw '进程身份与本项目记录不一致，未停止任何进程。'
}
$process = Get-Process -Id $musicProcess.ProcessId -ErrorAction SilentlyContinue
if (-not $process) { Write-Output '后台播放器已经关闭。'; return }
try {
    $null = $process.Handle
    if (-not (Test-MusicProcess $record $expectedScript)) {
        throw '进程身份与本项目记录不一致，未停止任何进程。'
    }
    Stop-Process -InputObject $process
    if ($Wait -and -not $process.WaitForExit(5000)) {
        throw '旧播放器未能退出。请稍等片刻再重试。'
    }
} finally { $process.Dispose() }
Write-Output '本地服务已停止，原生音频进程会随之退出。'


