param([string]$RuntimeRoot)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('便携 启动测试 ' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $temp '播放器 包'
$game = Join-Path $temp '模拟 游戏'
$ps = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Run-Script([string]$Name, [string[]]$Arguments = @(), [switch]$Fail) {
    $ErrorActionPreference = 'Continue'
    $output = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package $Name) @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($Fail) { Assert ($code -ne 0) ('应拒绝 ' + $Name) }
    else { Assert ($code -eq 0) ($Name + ' 失败 ' + ($output -join "`n")) }
    return ($output -join "`n")
}
New-Item -ItemType Directory -Path $package,(Join-Path $game 'data/databundles'),(Join-Path $package 'mod/scripts'),(Join-Path $package 'mod/images') -Force | Out-Null
foreach ($name in @('Install-Mod.ps1','Start-Player.ps1','Stop-Player.ps1','Runtime-Paths.ps1','Check-Environment.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $package
    $bytes = [IO.File]::ReadAllBytes((Join-Path $package $name))
    Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('缺少 BOM ' + $name)
}
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open((Join-Path $game 'data/databundles/scripts.zip'), [IO.Compression.ZipArchiveMode]::Create)
$zip.Dispose()
foreach ($name in @('modinfo.lua','modmain.lua','scripts/test.lua','images/test.xml')) {
    'fixture' | Set-Content -LiteralPath (Join-Path $package ('mod/' + $name))
}
$null = Run-Script 'Install-Mod.ps1' @('-GamePath',$game)
$configPath = Join-Path $package '.state/bridge.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($config.host -eq '127.0.0.1' -and $config.port -eq 17863 -and $config.token -cmatch '^[a-f0-9]{64}$') '首次 token 生成失败'
$target = Join-Path $game 'mods/local_netease_music'
$installed = Get-Content -LiteralPath (Join-Path $package '.state/install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($installed.modDir -ceq $target) '中文安装记录路径损坏'
Assert (Test-Path -LiteralPath (Join-Path $target 'scripts/dangomusic_connection.lua')) '未安装连接 Lua'
'user addition' | Set-Content -LiteralPath (Join-Path $target 'custom.txt')
'user edit' | Set-Content -LiteralPath (Join-Path $target 'modmain.lua')
foreach ($icon in @('modicon.xml','modicon.tex')) { 'optional icon' | Set-Content -LiteralPath (Join-Path $package ('mod/' + $icon)) }
$pcm = Join-Path $package '.state/正在播放.audio.pcm'
$share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
$writer = [IO.FileStream]::new($pcm, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, $share, 65536, [IO.FileOptions]::DeleteOnClose)
try {
    $reader = [IO.FileStream]::new($pcm, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $writer.Dispose()
        $output = Run-Script 'Install-Mod.ps1' @('-GamePath',$game)
        Assert ($reader.CanRead) '重复安装关闭了播放器的音频缓存'
    } finally { $reader.Dispose() }
} finally { $writer.Dispose() }
Assert (-not [IO.File]::Exists($pcm)) '播放器关闭最后一个句柄后未清理 PCM 缓存'
Assert (-not $output.Contains($config.token)) '输出包含 secret'
Assert ((Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).token -ceq $config.token) '重复安装更换 token'
Assert (Test-Path -LiteralPath (Join-Path $target 'custom.txt')) '用户新增文件丢失'
foreach ($icon in @('modicon.xml','modicon.tex')) { Assert (Test-Path -LiteralPath (Join-Path $target $icon) -PathType Leaf) ('未复制可选图标 ' + $icon) }
Assert (-not (Test-Path -LiteralPath (Join-Path $target 'music_workshop_identity.json'))) '本地安装误带工坊身份'
$backups = @(Get-ChildItem -LiteralPath (Join-Path $package '.state/backups') -Recurse -Filter modmain.lua)
Assert ($backups.Count -eq 1 -and (Get-Content -LiteralPath $backups[0].FullName -Raw -Encoding UTF8).Trim() -eq 'user edit') '未备份用户编辑'
# Without bridge.json the old generated Lua remains the migration source.
Remove-Item -LiteralPath $configPath
$null = Run-Script 'Install-Mod.ps1' @('-GamePath',$game)
Assert ((Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).token -ceq $config.token) '旧版 Lua token 未保留'
$before = Get-Content -LiteralPath (Join-Path $target 'modmain.lua') -Raw -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $target 'music_bridge_owned.txt')
$null = Run-Script 'Install-Mod.ps1' @('-GamePath',$game) -Fail
Assert ((Get-Content -LiteralPath (Join-Path $target 'modmain.lua') -Raw -Encoding UTF8) -ceq $before) '覆盖无 marker 目录'
'dst-local-music-prototype-v1' | Set-Content -LiteralPath (Join-Path $target 'music_bridge_owned.txt')
# A junction nested under the owned destination must be rejected before copying.
$outside = Join-Path $temp '外部 内容'
New-Item -ItemType Directory -Path $outside -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $target 'linked') -Target $outside | Out-Null
$null = Run-Script 'Install-Mod.ps1' @('-GamePath',$game) -Fail
Assert (@(Get-ChildItem -LiteralPath $outside).Count -eq 0) '写入 junction 外部'
[IO.Directory]::Delete((Join-Path $target 'linked'))
# Invalid connection cannot be silently replaced.
$config.host = '0.0.0.0'
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
$null = Run-Script 'Install-Mod.ps1' @('-GamePath',$game) -Fail
# CheckOnly never starts a server, even when a runtime is absent.
$empty = Join-Path $temp '仅检查 包'
New-Item -ItemType Directory -Path $empty | Out-Null
Copy-Item -LiteralPath (Join-Path $package 'Start-Player.ps1'),(Join-Path $package 'Runtime-Paths.ps1'),(Join-Path $package 'Check-Environment.ps1') -Destination $empty
$ErrorActionPreference = 'Continue'
$output = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $empty 'Start-Player.ps1') -CheckOnly 2>&1
Assert ($LASTEXITCODE -ne 0) '缺运行库检查应失败'
Assert (-not (Test-Path -LiteralPath (Join-Path $empty '.state'))) 'CheckOnly 创建状态目录'
if ($RuntimeRoot) {
    Copy-Item -LiteralPath $RuntimeRoot -Destination (Join-Path $empty 'runtime') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $empty 'helper') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'helper/native-deps') -Destination (Join-Path $empty 'helper/native-deps') -Recurse -Force
    $ErrorActionPreference = 'Continue'
    $output = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $empty 'Start-Player.ps1') -CheckOnly 2>&1
    Assert ($LASTEXITCODE -eq 0) ('包内运行库检查失败 ' + ($output -join "`n"))
    Assert (-not (Test-Path -LiteralPath (Join-Path $empty '.state'))) '检查创建状态目录'
}
Write-Output ('PASS 安装、PCM 待删除时重复安装、旧token、备份、marker保护、junction拒绝、中文空格路径、BOM、只读环境检查。夹具保留在 ' + $temp)



