param([switch]$NoBrowser, [switch]$Browser, [switch]$CheckOnly, [string]$StateDir)
$ErrorActionPreference = 'Stop'
$musicRoot = $PSScriptRoot
if (-not $StateDir) { $StateDir = Join-Path $musicRoot '.state' }
$stateDir = [IO.Path]::GetFullPath($StateDir)
$serverScript = Join-Path $musicRoot 'helper/server.mjs'
. (Join-Path $musicRoot 'Runtime-Paths.ps1')
if ($CheckOnly) { & (Join-Path $musicRoot 'Check-Environment.ps1'); return }
Assert-MusicSafePath $stateDir
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$runtime = Get-MusicRuntime
$nodeExe = $runtime.Node
$installRecord = Join-Path $stateDir 'install.json'
if (-not (Test-Path -LiteralPath $installRecord)) { throw '请先双击安装客户端Mod或连接工坊Mod，再启动播放器。' }
$configPath = Join-Path $stateDir 'bridge.json'
Assert-MusicSafePath $stateDir -Tree
try { $installLock = [IO.File]::Open((Join-Path $stateDir 'install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch { throw '安装或连接程序正在运行，请等待完成后重试。' }
try {
    $installed = Read-MusicInstallation $installRecord
    $runtimeModDir = $installed.modDir
    $fontsPath = Join-Path $installed.gameDir 'data/databundles/fonts.zip'
    Assert-MusicSafePath $fontsPath
    if (-not (Test-Path -LiteralPath $configPath)) { throw '连接配置缺失，请重新安装客户端 Mod 或连接工坊 Mod。' }
    $config = Read-MusicConnection $configPath
    Assert-MusicServiceConnectionTarget $stateDir $runtimeModDir $fontsPath -AllowLegacy:($installed.mode -cne 'workshop')
    Write-MusicModConnection $runtimeModDir $config
    $connected = $false
    if (Test-Path -LiteralPath $configPath) {
        $config = Read-MusicConnection $configPath
        if ($config.host -ne '127.0.0.1' -or $config.port -ne 17863) { throw '本机配置端口与 Mod 不匹配。' }
        try {
            $result = Invoke-RestMethod -Uri 'http://127.0.0.1:17863/api/status' -Headers @{ Authorization = "Bearer $($config.token)" } -TimeoutSec 2
            $connected = $result.ok -eq $true
        } catch {}
    }
    if (-not $connected) {
        $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        if (@($listeners | Where-Object { $_.Port -eq 17863 }).Count -gt 0) { throw '17863 端口已由其他进程或另一副本占用，已停止。' }
        $serverArgs = @(('"' + $serverScript + '"'), '--state-dir', ('"' + $stateDir + '"'), '--python', ('"' + $runtime.Python + '"'), '--runtime-mod-dir', ('"' + $runtimeModDir + '"'), '--fonts-path', ('"' + $fontsPath + '"'))
        $process = Start-Process -FilePath $nodeExe -ArgumentList $serverArgs -WorkingDirectory $musicRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stateDir 'server.log') -RedirectStandardError (Join-Path $stateDir 'server-error.log')
        $identity = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
        if (-not $identity) { throw '本机服务未能启动，请查看 .state/server-error.log。' }
        @{ pid = $process.Id; script = $serverScript; executable = $nodeExe; created = $identity.CreationDate.ToUniversalTime().ToString('o'); runtimeModDir = $runtimeModDir; fontsPath = $fontsPath } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'process.json') -Encoding UTF8
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            Start-Sleep -Milliseconds 200
            $process.Refresh()
            if ($process.HasExited) { throw '本机服务未能启动。请查看 .state/server-error.log（可能是端口被占用）。' }
            if (Test-Path -LiteralPath $configPath) {
                $config = Read-MusicConnection $configPath
                try {
                    $result = Invoke-RestMethod -Uri 'http://127.0.0.1:17863/api/status' -Headers @{ Authorization = "Bearer $($config.token)" } -TimeoutSec 1
                    if ($result.ok) { $connected = $true; break }
                } catch {}
            }
        }
    }
    if (-not $connected) { throw '本机服务启动超时，请查看 .state/server-error.log。' }
    $record = Get-Content -LiteralPath (Join-Path $stateDir 'process.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-MusicProcess $record $serverScript)) {
        throw '本机端口的服务不属于当前启动器记录，请先检查服务进程。'
    }
    Assert-MusicServiceConnectionTarget $stateDir $runtimeModDir $fontsPath -AllowLegacy:($installed.mode -cne 'workshop')
} finally { $installLock.Dispose() }
Write-Output '本地播放器服务已就绪。'
$nativeScript = Join-Path $musicRoot 'helper/NativePlayer.ps1'
$nativeRecordPath = Join-Path $stateDir 'native-process.json'
$nativeRunning = $false
if (Test-Path -LiteralPath $nativeRecordPath) {
    $nativeRecord = Get-Content -LiteralPath $nativeRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $nativeRunning = (Test-MusicProcess $nativeRecord $nativeScript) -and $nativeRecord.parentPid -eq $record.pid
}
if (-not $nativeRunning) {
    $powershellExe = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $nativeArgs = @('-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $nativeScript + '"'),'-StateDir',('"' + $stateDir + '"'),'-ParentProcessId',[string]$record.pid)
    $nativeProcess = Start-Process -FilePath $powershellExe -ArgumentList $nativeArgs -WorkingDirectory $musicRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stateDir 'native.log') -RedirectStandardError (Join-Path $stateDir 'native-error.log')
    @{pid=$nativeProcess.Id;script=$nativeScript;executable=$powershellExe;parentPid=$record.pid} | ConvertTo-Json | Set-Content -LiteralPath $nativeRecordPath -Encoding UTF8
}
$nativeReady = $false
for ($attempt=0; $attempt -lt 60; $attempt++) {
    $result = Invoke-RestMethod -Uri 'http://127.0.0.1:17863/api/status' -Headers @{Authorization="Bearer $($config.token)"} -TimeoutSec 2
    if ($result.playerConnected -and $result.playerEngine -eq 'native') { $nativeReady=$true; break }
    if ($nativeProcess) { $nativeProcess.Refresh(); if ($nativeProcess.HasExited) { break } }
    Start-Sleep -Milliseconds 300
}
if (-not $nativeReady) { throw '原生播放器未连接。请关闭旧网页播放端后重试，或查看 .state/native-error.log。' }
Write-Output '原生音频已连接。进入游戏按 F8；无需打开或保留网页。'
if ($Browser -and -not $NoBrowser) { Start-Process ('http://127.0.0.1:17863/#token=' + $config.token) }




