param([string]$GamePath, [string]$ModPath, [switch]$CheckOnly, [string]$StateDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime-Paths.ps1')
$connection = Find-MusicWorkshopConnection $GamePath $ModPath
if (-not $StateDir) { $StateDir = Join-Path $PSScriptRoot '.state' }
$stateDir = [IO.Path]::GetFullPath($StateDir)
Assert-MusicSafePath $stateDir -Tree
$fontsPath = Join-Path $connection.gameDir 'data/databundles/fonts.zip'
Assert-MusicServiceConnectionTarget $stateDir $connection.modDir $fontsPath
$configPath = Join-Path $stateDir 'bridge.json'
if (Test-Path -LiteralPath $configPath) { $config = Read-MusicConnection $configPath }
if ($CheckOnly) {
    Write-Output ('工坊连接检查通过，Mod 位于 ' + $connection.modDir)
    return
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
try { $installLock = [IO.File]::Open((Join-Path $stateDir 'install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch { throw '另一个安装或连接程序正在运行，请等待完成后重试。' }
try {
    # Revalidate under the shared lock before touching configuration.
    $modDir = Assert-MusicWorkshopMod $connection.modDir $connection.gameDir
    Assert-MusicServiceConnectionTarget $stateDir $modDir $fontsPath
    if (Test-Path -LiteralPath $configPath) { $config = Read-MusicConnection $configPath }
    else { $config = New-MusicConnection }
    Write-MusicText $configPath ($config | ConvertTo-Json)
    Write-MusicModConnection $modDir $config
    Write-MusicText (Join-Path $stateDir 'install.json') (@{mode='workshop';gameDir=$connection.gameDir;modDir=$modDir} | ConvertTo-Json)
    Write-Output ('已连接工坊 Mod，目录为 ' + $modDir)
    if (Test-Path -LiteralPath (Join-Path $connection.gameDir 'mods/local_netease_music') -PathType Container) {
        Write-Output '检测到旧本地客户端 Mod。请在游戏中关闭旧本地 Mod，只启用工坊版本。'
    }
    Write-Output '现在可双击启动播放器。进入游戏启用客户端 Mod，按 F8 打开。'
} finally { $installLock.Dispose() }
