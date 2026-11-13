param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('工坊 连接测试 ' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $temp '播放器 包'
$steamApps = Join-Path $temp 'Steam 中文库/steamapps'
$game = Join-Path $steamApps "common/Don't Starve Together"
$legacy = Join-Path $game 'mods/workshop-123456'
$modern = Join-Path $steamApps 'workshop/content/322330/987654'
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
function New-Mod([string]$Path) {
    New-Item -ItemType Directory -Path (Join-Path $Path 'scripts') -Force | Out-Null
    foreach ($name in @('modinfo.lua','modmain.lua','scripts/source.lua')) { [IO.File]::WriteAllText((Join-Path $Path $name), 'original source') }
    [IO.File]::WriteAllText((Join-Path $Path 'music_workshop_identity.json'), '{"schema":1,"id":"zcc-dst-music","channel":"workshop-beta","version":"beta-test"}')
}
function Snapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return ((Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n")
}
New-Item -ItemType Directory -Path $package,(Join-Path $game 'data/databundles') -Force | Out-Null
foreach ($name in @('Connect-Workshop.ps1','Install-Mod.ps1','Start-Player.ps1','Runtime-Paths.ps1','Check-Environment.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $package
    $bytes = [IO.File]::ReadAllBytes((Join-Path $package $name))
    Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('缺少 BOM ' + $name)
}
foreach ($name in @('scripts.zip','fonts.zip')) { [IO.File]::WriteAllText((Join-Path $game ('data/databundles/' + $name)), 'fixture') }
New-Mod $legacy
$before = Snapshot $temp
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-CheckOnly')
Assert ((Snapshot $temp) -ceq $before) 'CheckOnly 改写文件'
Assert (-not (Test-Path -LiteralPath (Join-Path $package '.state'))) 'CheckOnly 创建状态目录'
$output = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game)
$configPath = Join-Path $package '.state/bridge.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($config.token -cmatch '^[a-f0-9]{64}$') '工坊首次 token 生成错误'
Assert (-not $output.Contains($config.token)) '工坊连接输出 token'
$installed = Get-Content -LiteralPath (Join-Path $package '.state/install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($installed.mode -ceq 'workshop' -and $installed.gameDir -ceq $game -and $installed.modDir -ceq $legacy) 'legacy/中文路径安装记录错误'
Assert ((Get-Content -LiteralPath (Join-Path $legacy 'modmain.lua') -Raw) -ceq 'original source') '覆盖订阅源码'
$local = Join-Path $game 'mods/local_netease_music'
New-Item -ItemType Directory -Path $local -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $local 'user.txt'), 'keep local')
New-Mod $modern
$output = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$modern)
Assert ($output.Contains('关闭旧本地 Mod')) '缺少关闭旧客户端提示'
Assert ((Get-Content -LiteralPath (Join-Path $local 'user.txt') -Raw) -ceq 'keep local') '改动旧本地 Mod'
Assert (-not $output.Contains($config.token)) '重复连接输出 token'
Assert ((Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).token -ceq $config.token) '重复连接更换 token'
$installed = Get-Content -LiteralPath (Join-Path $package '.state/install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($installed.modDir -ceq $modern) 'modern 安装记录错误'
$before = Snapshot $temp
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game) -Fail
Assert ((Snapshot $temp) -ceq $before) '多候选失败仍有写入'
# A caller can infer a normal Steam game path from either supported layout.
$null = Run-Script 'Connect-Workshop.ps1' @('-ModPath',$modern,'-CheckOnly')
$null = Run-Script 'Connect-Workshop.ps1' @('-ModPath',$legacy,'-CheckOnly')
$otherGame = Join-Path $temp '其他游戏'
New-Item -ItemType Directory -Path (Join-Path $otherGame 'data/databundles') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $otherGame 'data/databundles/scripts.zip'), 'fixture')
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$otherGame,'-ModPath',$modern) -Fail
$marker = Join-Path $modern 'music_workshop_identity.json'
$originalMarker = [IO.File]::ReadAllText($marker)
foreach ($text in @('{"schema":1,"id":"other","channel":"workshop-beta"}', '{"schema":true,"id":"zcc-dst-music","channel":"workshop-beta"}', '{"schema":1,"id":"zcc-dst-music","channel":"release"}', '{"schema":1,"id":"zcc-dst-music","channel":"workshop-beta","unknown":true}', '{"schema":1,"id":"zcc-dst-music","channel":"workshop-beta","version":1}', 'invalid json')) {
    [IO.File]::WriteAllText($marker, $text)
    $before = Snapshot $temp
    $null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$modern) -Fail
    Assert ((Snapshot $temp) -ceq $before) '伪造身份失败仍写入'
}
Remove-Item -LiteralPath $marker
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$modern) -Fail
[IO.File]::WriteAllText($marker, $originalMarker)
$outside = Join-Path $temp '伪装 Mod'
New-Mod $outside
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$outside) -Fail
$linkOutside = Join-Path $temp 'junction 外部'
New-Item -ItemType Directory -Path $linkOutside -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $modern 'scripts/linked') -Target $linkOutside | Out-Null
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$modern) -Fail
Assert (@(Get-ChildItem -LiteralPath $linkOutside).Count -eq 0) 'junction 外部被写入'
[IO.Directory]::Delete((Join-Path $modern 'scripts/linked'))
# Steam may replace the subscription files. Test the normal Start entry point with
# isolated runtime/status/process stubs, so no service or production port is used.
$luaPath = Join-Path $modern 'scripts/dangomusic_connection.lua'
Remove-Item -LiteralPath $luaPath
$stubs = @'
function Get-MusicRuntime { return @{Node='fixture-node';Python='fixture-python'} }
function Invoke-RestMethod { return @{ok=$true;playerConnected=$true;playerEngine='native'} }
function Test-MusicProcess { return $true }
function Start-Process { throw 'Fixture must never launch a process.' }
'@
Add-Content -LiteralPath (Join-Path $package 'Runtime-Paths.ps1') -Value $stubs -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $package '.state/process.json'), (@{pid=42;runtimeModDir=$modern;fontsPath=(Join-Path $game 'data/databundles/fonts.zip')} | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $package '.state/native-process.json'), '{"pid":43,"parentPid":42}')
$sourceBefore = [IO.File]::ReadAllText((Join-Path $modern 'modmain.lua'))
$output = Run-Script 'Start-Player.ps1' @('-NoBrowser')
Assert (Test-Path -LiteralPath $luaPath -PathType Leaf) 'Start 未恢复 Steam 删除的连接文件'
Assert ([IO.File]::ReadAllText($luaPath).Contains($config.token)) 'Start 恢复 token 错误'
Assert (-not $output.Contains($config.token)) 'Start 输出 token'
Assert ([IO.File]::ReadAllText((Join-Path $modern 'modmain.lua')) -ceq $sourceBefore) 'Start 覆盖订阅源码'
$before = Snapshot $temp
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$modern,'-CheckOnly')
Assert ((Snapshot $temp) -ceq $before) '已有状态时 CheckOnly 改写文件'
# The retained local installer must reject a switch away from an active workshop service.
New-Mod (Join-Path $package 'mod')
New-Item -ItemType Directory -Path (Join-Path $package 'mod/images') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $local 'music_bridge_owned.txt'), 'dst-local-music-prototype-v1')
$before = Snapshot $temp
$output = Run-Script 'Install-Mod.ps1' @('-GamePath',$game) -Fail
Assert ($output.Contains('停止播放器')) 'Install 未拒绝活动工坊服务切换'
Assert ((Snapshot $temp) -ceq $before) '活动工坊转local失败仍改写state或Mod'
# An owned service from the local installation cannot be reused or reconfigured.
[IO.File]::WriteAllText((Join-Path $package '.state/process.json'), (@{pid=42;runtimeModDir=$local;fontsPath=(Join-Path $game 'data/databundles/fonts.zip')} | ConvertTo-Json))
$before = Snapshot $temp
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$modern) -Fail
Assert ((Snapshot $temp) -ceq $before) '活动服务切换失败仍写入'
$output = Run-Script 'Start-Player.ps1' @('-NoBrowser') -Fail
Assert ($output.Contains('停止播放器')) 'Start 未拒绝旧服务目标'
[IO.File]::WriteAllText((Join-Path $package '.state/process.json'), '{"pid":42}')
$null = Run-Script 'Start-Player.ps1' @('-NoBrowser') -Fail
$before = Snapshot $temp
$null = Run-Script 'Connect-Workshop.ps1' @('-GamePath',$game,'-ModPath',$modern) -Fail
Assert ((Snapshot $temp) -ceq $before) '旧进程记录失败仍写入'
# Legacy process records remain compatible when the owned local installation proves the target.
[IO.File]::WriteAllText((Join-Path $package '.state/install.json'), (@{modDir=$local;gameDir=$game} | ConvertTo-Json))
$null = Run-Script 'Install-Mod.ps1' @('-GamePath',$game)
Assert ((Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).token -ceq $config.token) '旧local活动记录兼容时更换token'
Assert (-not (Test-Path -LiteralPath (Join-Path $local 'music_workshop_identity.json'))) '保留local入口误复制工坊身份'
# Exercise registry-independent multi-library discovery through the shared helper.
. (Join-Path $root 'Runtime-Paths.ps1')
function Get-MusicSteamLibraries { return (Split-Path $steamApps -Parent) }
$failed = $false
try { $null = Find-MusicWorkshopConnection } catch { $failed = $_.Exception.Message.Contains('2 个') }
Assert $failed '自动发现未拒绝多候选'
Write-Output ('PASS 工坊两种布局、身份与关联校验、中文路径、token保留与保密、多候选、junction、旧Mod保留、只读检查、Start更新后恢复、活动服务切换/旧进程记录拒绝。Start使用隔离状态/进程桩。夹具保留在 ' + $temp)
