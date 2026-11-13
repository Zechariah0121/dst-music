param([string]$GamePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime-Paths.ps1')
$musicRoot = $PSScriptRoot
$source = Join-Path $musicRoot 'mod'
if (-not $GamePath) {
    $candidates = @(Get-MusicSteamGamePaths)
    if ($candidates.Count -ne 1) { throw '无法唯一确定游戏安装目录。请使用 Install-Mod.ps1 -GamePath 指定路径。' }
    $GamePath = $candidates[0]
}
$gameRoot = (Resolve-Path -LiteralPath $GamePath).Path
if (-not (Test-Path -LiteralPath (Join-Path $gameRoot 'data/databundles/scripts.zip') -PathType Leaf)) { throw '指定目录不是 DST 游戏安装目录。' }
$modsRoot = [IO.Path]::GetFullPath((Join-Path $gameRoot 'mods'))
$target = [IO.Path]::GetFullPath((Join-Path $modsRoot 'local_netease_music'))
if (-not $target.StartsWith($modsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '安装目标超出 mods 目录，已停止。' }
Assert-MusicSafePath $source -Tree
Assert-MusicSafePath $target -Tree
$stateDir = Join-Path $musicRoot '.state'
Assert-MusicSafePath $stateDir -Tree
$marker = Join-Path $target 'music_bridge_owned.txt'
if (Test-Path -LiteralPath $target) {
    if (-not (Test-Path -LiteralPath $target -PathType Container) -or -not (Test-Path -LiteralPath $marker -PathType Leaf) -or (Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim() -ne 'dst-local-music-prototype-v1') { throw '目标目录已有其他内容，未覆盖。请先检查 local_netease_music。' }
}
foreach ($name in @('modinfo.lua','modmain.lua','scripts','images')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) { throw 'Mod 安装源文件不完整，请重新解压发行包。' }
}
# bridge.json is authoritative. An older package may only have its generated Lua.
$fontsPath = Join-Path $gameRoot 'data/databundles/fonts.zip'
Assert-MusicSafePath $fontsPath
Assert-MusicServiceConnectionTarget $stateDir $target $fontsPath -AllowLegacy
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
try { $installLock = [IO.File]::Open((Join-Path $stateDir 'install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch { throw '另一个安装程序正在运行，请等待完成后重试。' }
try {
Assert-MusicServiceConnectionTarget $stateDir $target $fontsPath -AllowLegacy
$configPath = Join-Path $stateDir 'bridge.json'
$luaPath = Join-Path $source 'scripts/dangomusic_connection.lua'
if (Test-Path -LiteralPath $configPath) {
    $config = Read-MusicConnection $configPath
} else {
    $token = $null
    if (Test-Path -LiteralPath $luaPath) {
        $lua = Get-Content -LiteralPath $luaPath -Raw -Encoding UTF8
        $match = [regex]::Match($lua, '^\s*return\s*\{\s*host="127\.0\.0\.1",\s*port=17863,\s*token="([a-zA-Z0-9_-]{24,128})"\s*\}\s*$')
        if (-not $match.Success) { throw '旧版 Lua 连接配置无效，已停止安装。' }
        $token = $match.Groups[1].Value
    }
    if (-not $token) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $token = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    $config = @{host='127.0.0.1';port=17863;token=$token}
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
if (Test-Path -LiteralPath $target) {
    $backup = Join-Path $stateDir ('backups/mod-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Copy-Item -LiteralPath $target -Destination $backup -Recurse -Force
    Write-Output ('旧副本及用户修改已备份到 ' + $backup)
}
# Node consumes UTF-8 JSON without a BOM.

Write-MusicText $configPath ($config | ConvertTo-Json)
Write-MusicText $luaPath ('return {host="127.0.0.1",port=17863,token="' + $config.token + '"}' + "`n")
New-Item -ItemType Directory -Path $target -Force | Out-Null
# Overlay keeps user-added files. Every overwritten file is retained in backup.
$copyNames = @('modinfo.lua','modmain.lua','scripts','images')
foreach ($icon in @('modicon.xml','modicon.tex')) {
    if (Test-Path -LiteralPath (Join-Path $source $icon) -PathType Leaf) { $copyNames += $icon }
}
foreach ($name in $copyNames) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $target -Recurse -Force
}
'dst-local-music-prototype-v1' | Set-Content -LiteralPath $marker -Encoding ASCII
Write-MusicText (Join-Path $stateDir 'install.json') (@{mode='local';modDir=$target;gameDir=$gameRoot} | ConvertTo-Json)
Write-Output ('Mod 已安装到 ' + $target)
Write-Output '现在可双击启动播放器。进入游戏启用客户端 Mod，按 F8 打开。'


} finally { $installLock.Dispose() }

