$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$game = Join-Path $fixture "Steam 库/steamapps/common/Don't Starve Together"
$workshop = Join-Path $fixture 'Steam 库/steamapps/workshop/content/322330/3836261433'
$launcherDir = Join-Path $workshop 'windows-player'
$localData = Join-Path $fixture '户'
$defaultInstall = Join-Path $localData 'Zcc/DST-Music/Workshop/3836261433'
$locationRecord = Join-Path $defaultInstall 'install-location.json'
$install = Join-Path $fixture '自选 目录/云间音乐'
$state = Join-Path $install '.state'
$ps = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Fixture([string]$Path, [string]$Content) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($true))
}
function Run-Launcher([string]$Path, [string[]]$Arguments, [switch]$Fail) {
    $ErrorActionPreference = 'Continue'
    $result = & $ps -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    Assert (($LASTEXITCODE -ne 0) -eq $Fail.IsPresent) $result
    return $result
}

function Set-FixtureLauncher([string]$LocalData) {
    $launcher = $launcherSource.Replace('[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)', "'" + $LocalData.Replace("'", "''") + "'")
    $launcher = $launcher.Replace('[Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port -contains 17863', '(Test-Path -LiteralPath (Join-Path $stateDir ''fixture-port-busy''))')
    $launcher = $launcher.Replace($pickerDefinition.Extent.Text, @'
function Show-WorkshopInstallDirectory([string]$DefaultDirectory, [string]$SourceModPath, [string]$PreviousDirectory, [string]$RecoveryReason) {
    [IO.File]::AppendAllText((Join-Path $env:fixtureWorkspace 'fixture-picker.log'), $DefaultDirectory + "`n")
    if ($PreviousDirectory) { [IO.File]::AppendAllText((Join-Path $env:fixtureWorkspace 'fixture-recovery.log'), $PreviousDirectory + '|' + $RecoveryReason + "`n") }
    if ($env:fixturePickerHold) {
        [IO.File]::WriteAllText($env:fixturePickerHold, 'picker ready')
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ([IO.File]::Exists($env:fixturePickerHold) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 30 }
    }
    if ($env:fixtureChoice -ceq 'default') { return $DefaultDirectory }
    if ($env:fixtureChoice -ceq 'cancel') { return }
    return $env:fixtureChoice
}
'@)
    $launcher = $launcher.Replace($settingsDefinition.Extent.Text, @'
function Show-AutoStartSettings { Write-Output ('Autostart settings for ' + $installDir) }
'@)
    $launcher = $launcher.Replace($autostartDefinition.Extent.Text, @'
function Get-AutoStartEntry {
    if ([IO.File]::Exists($env:fixtureRunFile)) { return @{kind=[Microsoft.Win32.RegistryValueKind]::String;value=[IO.File]::ReadAllText($env:fixtureRunFile)} }
}
function Set-ItemProperty {
    param($LiteralPath, $Name, $Value)
    if ($LiteralPath -cne $runKey -or $Name -cne $runName -or -not [IO.File]::Exists($currentPath) -or
        -not [IO.File]::Exists((Join-Path $stateDir 'fixture-start.log'))) { throw '恢复自启动发生在安装或启动成功之前' }
    [IO.File]::WriteAllText($env:fixtureRunFile, $Value)
    [IO.File]::AppendAllText((Join-Path $env:fixtureWorkspace 'fixture-registry-write.log'), "update`n")
}
'@)
    Write-Fixture $launcherPath $launcher
}
function New-Bundle([string]$Version, [string]$ExtraMember, [switch]$BadHash, [switch]$BadRuntime, [switch]$BadStart) {
    $package = 'DST-Music-' + $Version + '-Windows-Companion'
    $zip = Join-Path $launcherDir ($package + '.zip')
    $files = @{
        'Start-Player.ps1' = @'
param([string]$StateDir, [switch]$NoBrowser, [switch]$CheckOnly)
if ($CheckOnly) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fixture-bad-runtime')) { throw 'invalid runtime' }
    return
}
if (-not $NoBrowser -or -not $StateDir) { throw 'Missing launcher arguments' }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fixture-bad-start')) { throw 'fixture runtime launch failed' }
[IO.File]::AppendAllText((Join-Path $StateDir 'fixture-start.log'), "start`n")
'@
        'Stop-Player.ps1' = @'
param([string]$StateDir, [switch]$Wait)
[IO.File]::AppendAllText((Join-Path $StateDir 'fixture-stop.log'), "stop (wait: $Wait)`n")
'@
        'Connect-Workshop.ps1' = [IO.File]::ReadAllText((Join-Path $root 'Connect-Workshop.ps1'))
        'Check-Environment.ps1' = 'fixture'
        'Runtime-Paths.ps1' = [IO.File]::ReadAllText((Join-Path $root 'Runtime-Paths.ps1'))
        'helper/server.mjs' = 'fixture'
        'helper/NativePlayer.ps1' = 'fixture'
        'runtime/node/node.exe' = 'fixture'
        'runtime/python/python.exe' = 'fixture'
    }
    if ($ExtraMember) { $files[$ExtraMember] = 'unsafe' }
    if ($BadRuntime) { $files['fixture-bad-runtime'] = 'invalid runtime' }
    if ($BadStart) { $files['fixture-bad-start'] = 'invalid start' }
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $files.Keys) {
            $entry = $archive.CreateEntry($package + '/' + $name)
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($true))
            try { $writer.Write($files[$name]) } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($BadHash) { $hash = '0' * 64 }
    Write-Fixture (Join-Path $launcherDir 'companion.json') (@{schema=1;package=$package;sha256=$hash} | ConvertTo-Json)
    return $zip
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Write-Fixture (Join-Path $game 'data/databundles/scripts.zip') 'fixture'
Write-Fixture (Join-Path $workshop 'modinfo.lua') '-- fixture'
Write-Fixture (Join-Path $workshop 'modmain.lua') '-- fixture'
Write-Fixture (Join-Path $workshop 'scripts/fixture.lua') '-- fixture'
Write-Fixture (Join-Path $workshop 'music_workshop_identity.json') '{"schema":1,"id":"zcc-dst-music","channel":"workshop-beta","version":"0.6.0-beta.1"}'
foreach ($name in @('自启动设置.cmd', '停止配套播放器.cmd')) {
    Write-Fixture (Join-Path $workshop $name) 'fixture cmd'
    Write-Fixture (Join-Path $launcherDir $name) 'fixture cmd'
}
Copy-Item -LiteralPath (Join-Path $root 'Runtime-Paths.ps1') -Destination $launcherDir
Add-Content -LiteralPath (Join-Path $launcherDir 'Runtime-Paths.ps1') -Encoding UTF8 -Value @'
function Test-MusicProcess($Record, [string]$Script) {
    return $Record.script -ceq $Script -and $Record.created -ceq 'owned-fixture'
}
'@
$launcherPath = Join-Path $launcherDir 'Launch-Workshop.ps1'
$launcherSourcePath = Join-Path $root 'release/workshop/Launch-Workshop.ps1'
$launcherSource = [IO.File]::ReadAllText($launcherSourcePath)
$tokens = $parseErrors = $null
$launcherAst = [Management.Automation.Language.Parser]::ParseFile($launcherSourcePath, [ref]$tokens, [ref]$parseErrors)
Assert (-not $parseErrors) 'Launcher failed PowerShell 5.1 syntax parsing'
$pickerDefinition = $launcherAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-WorkshopInstallDirectory'}, $false)
$settingsDefinition = $launcherAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-AutoStartSettings'}, $false)
$autostartDefinition = $launcherAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AutoStartEntry'}, $false)
Assert ($pickerDefinition -and $settingsDefinition -and $autostartDefinition) 'Could not stub the isolated launcher dialogs and registry'
$env:fixtureWorkspace = $fixture
$env:fixtureRunFile = Join-Path $fixture 'fixture-run-value.txt'
$pickerLog = Join-Path $fixture 'fixture-picker.log'
Set-FixtureLauncher $localData
$zip = New-Bundle '0.6.0-beta.1'
$lua = Join-Path $workshop 'scripts/dangomusic_connection.lua'

$env:fixtureChoice = 'cancel'
$null = Run-Launcher $launcherPath @('-Stop') -Fail
$null = Run-Launcher $launcherPath @('-Settings') -Fail
$null = Run-Launcher $launcherPath @('-AutoStart') -Fail
Assert (-not (Test-Path -LiteralPath $pickerLog)) 'A non-install action prompted for an installation directory'
$result = Run-Launcher $launcherPath
Assert ($result.Contains('已取消') -and -not (Test-Path -LiteralPath $lua) -and -not (Test-Path -LiteralPath $localData)) 'Cancel installed or connected the player'
Assert (([IO.File]::ReadAllText($pickerLog)).Trim() -ceq $defaultInstall) 'The first dialog did not receive the original default location'

$pickerHold = Join-Path $fixture 'fixture-picker-open'
$env:fixturePickerHold = $pickerHold
$child = Start-Process -FilePath $ps -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $launcherPath + '"') -PassThru -WindowStyle Hidden
try {
    $env:fixturePickerHold = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not [IO.File]::Exists($pickerHold) -and -not $child.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 30 }
    Assert ([IO.File]::Exists($pickerHold)) 'The simulated first dialog did not open'
    $result = Run-Launcher $launcherPath -Fail
    Assert ($result.Contains('正在选择安装目录')) 'A second invocation opened another simultaneous first-run dialog'
} finally {
    [IO.File]::Delete($pickerHold)
    $child.WaitForExit()
    $child.Dispose()
}
Assert (-not (Test-Path -LiteralPath $locationRecord)) 'Concurrent then cancelled first launch wrote a location record'

$env:fixtureChoice = '相对 目录'
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('完整的 Windows') -and -not (Test-Path -LiteralPath $locationRecord)) 'A relative installation path was accepted'
$env:fixtureChoice = $workshop
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('Steam 模组文件夹以外') -and -not (Test-Path -LiteralPath $locationRecord)) 'The subscribed Mod directory was accepted as an installation path'
$collision = Join-Path $fixture '别人的目录'
$foreignFile = Join-Path $collision '.state/keep.txt'
Write-Fixture $foreignFile 'do not overwrite'
$env:fixtureChoice = $collision
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('同名文件或目录') -and [IO.File]::ReadAllText($foreignFile) -ceq 'do not overwrite' -and -not (Test-Path -LiteralPath $locationRecord)) 'A collision path was taken over'
$env:fixtureChoice = $foreignFile
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('路径指向文件') -and -not (Test-Path -LiteralPath $locationRecord)) 'A file path was accepted as an installation directory'

$manifestPath = Join-Path $launcherDir 'companion.json'
$validManifest = [IO.File]::ReadAllText($manifestPath)
$badManifest = $validManifest | ConvertFrom-Json
$badManifest.sha256 = '0' * 64
Write-Fixture $manifestPath ($badManifest | ConvertTo-Json)
$env:fixtureChoice = $install + '\'
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('ZIP 校验失败') -and -not (Test-Path -LiteralPath $lua) -and -not (Test-Path -LiteralPath $state)) 'The failed first extraction connected or started the player'
$pickerCount = (Get-Content -LiteralPath $pickerLog).Count
$env:fixtureChoice = 'cancel'
Write-Fixture $manifestPath $validManifest
$result = Run-Launcher $launcherPath
Assert (Test-Path -LiteralPath $lua -PathType Leaf) 'First launch did not connect the precise subscribed Mod'
Assert (Test-Path -LiteralPath (Join-Path $state 'fixture-start.log') -PathType Leaf) 'First launch did not start the companion'
Assert ($result.Contains('ESC → 音乐播放器 → 连接播放器') -and $result.Contains($install)) 'First launch omitted in-game connection guidance or the install directory'
$savedLocation = [IO.File]::ReadAllText($locationRecord)
Assert (($savedLocation | ConvertFrom-Json).path -ceq $install) 'The custom location was not normalized and saved'
Assert (((Get-ChildItem -LiteralPath $defaultInstall -Force).Name -join ',') -ceq 'install-location.json') 'Program or data files were left behind at the default location'
Assert ((Get-Content -LiteralPath $pickerLog).Count -eq $pickerCount) 'Retrying a failed extraction discarded the confirmed location'
$connection = [IO.File]::ReadAllText($lua)
Assert ($result -notmatch '[a-f0-9]{64}') 'Launcher printed a token'
Write-Fixture (Join-Path $state 'fixture-private-settings.json') 'preserve this'
[IO.File]::Delete($zip)
$null = Run-Launcher $launcherPath
Assert ((Get-Content -LiteralPath (Join-Path $state 'fixture-start.log')).Count -eq 2) 'Same-version launch attempted re-extraction or failed to restart'
$stable = Join-Path $install 'Launch-Workshop.ps1'
$null = Run-Launcher $stable @('-AutoStart')
$null = Run-Launcher $stable @('-Stop')
Assert ((Get-Content -LiteralPath (Join-Path $state 'fixture-start.log')).Count -eq 3) 'Autostart did not resolve the validated installed version'
Assert (Test-Path -LiteralPath (Join-Path $state 'fixture-stop.log') -PathType Leaf) 'Stop did not use shared state'
Assert ((Run-Launcher $stable @('-Settings')).Contains($install)) 'Installed settings did not resolve the custom directory'
Assert ((Run-Launcher $launcherPath @('-Settings')).Contains($install)) 'Workshop settings did not resolve the custom directory'
Assert ((Get-Content -LiteralPath $pickerLog).Count -eq $pickerCount) 'Repeat launch and maintenance entries showed the installation dialog'

# 加载真实注册表辅助函数，但命令仅使用内存替身，不访问真实 HKCU Run。
& {
    . (Join-Path $root 'Runtime-Paths.ps1')
    $installDir = $install
    $versionsDir = Join-Path $install 'versions'
    $currentPath = Join-Path $install 'current.json'
    $runKey = 'Fixture:/Run'
    $runName = 'ZccDSTMusic'
    $script:fixtureRunEntry = $null
    $tokens = $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($launcherSourcePath, [ref]$tokens, [ref]$parseErrors)
    Assert (-not $parseErrors) 'Launcher failed PowerShell 5.1 syntax parsing'
    foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Test-Path {
        param($LiteralPath, $PathType)
        if ($LiteralPath -eq $runKey) { return $true }
        Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
    }
    function Get-Item {
        param($LiteralPath, [switch]$Force)
        if ($LiteralPath -ne $runKey) { return Microsoft.PowerShell.Management\Get-Item @PSBoundParameters }
        $key = [pscustomobject]@{}
        Add-Member -InputObject $key -MemberType ScriptMethod GetValueNames { if ($script:fixtureRunEntry) { 'ZccDSTMusic' } }
        Add-Member -InputObject $key -MemberType ScriptMethod GetValueKind { $script:fixtureRunEntry.kind }
        Add-Member -InputObject $key -MemberType ScriptMethod GetValue { $script:fixtureRunEntry.value }
        Add-Member -InputObject $key -MemberType ScriptMethod Dispose {}
        return $key
    }
    function New-ItemProperty {
        param($LiteralPath, $Name, $PropertyType, $Value)
        Assert ($LiteralPath -ceq $runKey -and $Name -ceq $runName) 'Unexpected registry write'
        $script:fixtureRunEntry = @{kind=[Microsoft.Win32.RegistryValueKind]::String;value=$Value}
    }
    function Remove-ItemProperty {
        param($LiteralPath, $Name)
        Assert ($LiteralPath -ceq $runKey -and $Name -ceq $runName) 'Unexpected registry removal'
        $script:fixtureRunEntry = $null
    }
    Assert (-not (Get-AutoStartEntry)) 'Autostart is enabled by default'
    Set-AutoStart $false
    Assert (-not (Get-AutoStartEntry)) 'Saving disabled autostart wrote a value'
    Set-AutoStart $true
    $command = (Get-AutoStartEntry).value
    Assert ($command.EndsWith(('-File "' + $stable + '" -AutoStart')) -and
        $command.Contains('-WindowStyle Hidden')) 'Autostart did not use the hidden stable path'
    Set-AutoStart $true
    Assert ((Get-AutoStartEntry).value -ceq $command) 'Saving an already enabled startup changed it'
    Set-AutoStart $false
    Assert (-not (Get-AutoStartEntry)) 'Disabling autostart retained the owned value'
    foreach ($entry in @(
        @{kind=[Microsoft.Win32.RegistryValueKind]::String;value='other startup app'},
        @{kind=[Microsoft.Win32.RegistryValueKind]::String;value=''},
        @{kind=[Microsoft.Win32.RegistryValueKind]::DWord;value=0},
        @{kind=[Microsoft.Win32.RegistryValueKind]::ExpandString;value=$command}
    )) {
        $script:fixtureRunEntry = $entry
        foreach ($enabled in @($true,$false)) {
            $failed = $false
            try { Set-AutoStart $enabled } catch { $failed = $true }
            Assert ($failed -and $script:fixtureRunEntry -eq $entry) 'An unrelated startup value was changed'
        }
    }
}

$oldVersion = (Get-ChildItem -LiteralPath (Join-Path $install 'versions') -Directory).FullName
$recordPath = Join-Path $state 'process.json'
$foreign = @{pid=42;script='foreign';executable='foreign';created='foreign';runtimeModDir=$workshop;fontsPath=(Join-Path $game 'data/databundles/fonts.zip')}
Write-Fixture $recordPath ($foreign | ConvertTo-Json)
$port = Join-Path $state 'fixture-port-busy'
Write-Fixture $port 'busy'
$null = New-Bundle '0.6.0-beta.2'
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('17863') -and (Get-Content -LiteralPath (Join-Path $state 'fixture-stop.log')).Count -eq 1) 'Foreign port process was accepted or stopped'
[IO.File]::Delete($port)
Write-Fixture $recordPath ((@{pid=42;script=(Join-Path $oldVersion 'helper/server.mjs');executable=(Join-Path $oldVersion 'runtime/node/node.exe');created='owned-fixture';runtimeModDir=$workshop;fontsPath=(Join-Path $game 'data/databundles/fonts.zip')}) | ConvertTo-Json)
$result = Run-Launcher $launcherPath
Assert ((Get-Content -LiteralPath (Join-Path $state 'fixture-stop.log'))[-1] -eq 'stop (wait: True)') 'Owned running player was not stopped and waited on for the upgrade'
Assert ((Get-ChildItem -LiteralPath (Join-Path $install 'versions') -Directory).Count -eq 2) 'Upgrade did not preserve the old package'
Assert (([IO.File]::ReadAllText($lua) -ceq $connection) -and
    ([IO.File]::ReadAllText((Join-Path $state 'fixture-private-settings.json')) -ceq 'preserve this')) 'Upgrade changed persistent state'
$before = [IO.File]::ReadAllText((Join-Path $install 'current.json'))
$currentVersion = Get-ChildItem -LiteralPath (Join-Path $install 'versions') -Directory | Where-Object Name -Like '*beta.2*'
Write-Fixture $recordPath ((@{pid=42;script=(Join-Path $currentVersion.FullName 'helper/server.mjs');executable=(Join-Path $currentVersion.FullName 'runtime/node/node.exe');created='owned-fixture';runtimeModDir=$workshop;fontsPath=(Join-Path $game 'data/databundles/fonts.zip')}) | ConvertTo-Json)
$stopCount = (Get-Content -LiteralPath (Join-Path $state 'fixture-stop.log')).Count
$null = New-Bundle '0.6.0-beta.5' -BadRuntime
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('环境检查失败') -and (Get-Content -LiteralPath (Join-Path $state 'fixture-stop.log')).Count -eq $stopCount) 'Invalid environment stopped the previous player'
$startCount = (Get-Content -LiteralPath (Join-Path $state 'fixture-start.log')).Count
$null = New-Bundle '0.6.0-beta.6' -BadStart
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('已恢复上次运行') -and (Get-Content -LiteralPath (Join-Path $state 'fixture-start.log')).Count -eq ($startCount + 1)) 'Failed launch did not restart the previous player'
Assert (([IO.File]::ReadAllText($lua) -ceq $connection) -and ([IO.File]::ReadAllText((Join-Path $install 'current.json')) -ceq $before)) 'Failed launch mutated current or Mod connection'
$null = New-Bundle '0.6.0-beta.3' -BadHash
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('ZIP 校验失败')) 'Wrong ZIP checksum did not produce a clear failure'
$null = New-Bundle '0.6.0-beta.4' '../../../escape.txt'
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('文件路径无效')) 'Unsafe ZIP path was accepted'
Assert (-not (Get-ChildItem -LiteralPath (Join-Path $install 'versions') -Force | Where-Object Name -Like '.extract-*')) 'Failed extraction left a staging directory'
Assert (([IO.File]::ReadAllText((Join-Path $install 'current.json')) -ceq $before) -and
    (-not (Get-ChildItem -LiteralPath $fixture -Recurse -Filter 'escape.txt'))) 'Failed extraction mutated the current installation or escaped the target'
[IO.File]::Delete($recordPath)
[IO.File]::Delete((Join-Path $currentVersion.FullName 'runtime/node/node.exe'))
$null = New-Bundle '0.6.0-beta.7'
$null = Run-Launcher $launcherPath
Assert (([IO.File]::ReadAllText((Join-Path $install 'current.json')) -match '0\.6\.0-beta\.7') -and
    ([IO.File]::ReadAllText($lua) -ceq $connection)) 'A damaged previous installation blocked the intact upgrade'

Write-Fixture $locationRecord '{wrong json'
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('无法读取播放器安装位置记录') -and [IO.File]::ReadAllText($locationRecord) -ceq '{wrong json') 'A corrupt location record was accepted or overwritten'
$null = Run-Launcher $stable @('-AutoStart') -Fail
$null = Run-Launcher $stable @('-Stop') -Fail
$null = Run-Launcher $launcherPath @('-Settings') -Fail
Assert ((Get-Content -LiteralPath $pickerLog).Count -eq $pickerCount) 'A corrupt saved record opened an installation dialog'
$missingInstall = Join-Path $fixture '磁盘已离线'
Write-Fixture $locationRecord (@{schema=1;path=$missingInstall} | ConvertTo-Json)
$missingRecord = [IO.File]::ReadAllText($locationRecord)
$result = Run-Launcher $launcherPath
Assert ($result.Contains('已取消') -and [IO.File]::ReadAllText($locationRecord) -ceq $missingRecord -and
    -not (Test-Path -LiteralPath $missingInstall) -and -not (Test-Path -LiteralPath (Join-Path $defaultInstall 'versions'))) 'Cancelling recovery recreated or moved the missing location'
Assert ((Get-Content -LiteralPath $pickerLog).Count -eq ($pickerCount + 1) -and
    [IO.File]::ReadAllText((Join-Path $fixture 'fixture-recovery.log')).Contains($missingInstall)) 'Missing saved location did not offer recovery with the previous path'
$result = Run-Launcher $launcherPath @('-Settings') -Fail
Assert ($result.Contains('重新选择') -and (Get-Content -LiteralPath $pickerLog).Count -eq ($pickerCount + 1)) 'A maintenance entry prompted for recovery or omitted the workshop recovery entry'
$env:fixtureChoice = $install
$null = Run-Launcher $launcherPath
Assert ([IO.File]::ReadAllText((Join-Path $state 'fixture-private-settings.json')) -ceq 'preserve this' -and
    ([IO.File]::ReadAllText($locationRecord) | ConvertFrom-Json).path -ceq $install) 'Recovery could not select the existing account directory'

# 模拟卸载后重新安装：先移走原目录保存账号，取消不得改指针或已启用的自启动项。
$parkedInstall = Join-Path $fixture '保留的播放器'
[IO.Directory]::Move($install, $parkedInstall)
$oldStartup = '"' + $ps + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $install 'Launch-Workshop.ps1') + '" -AutoStart'
Write-Fixture $env:fixtureRunFile $oldStartup
$env:fixtureChoice = 'cancel'
$result = Run-Launcher $launcherPath
Assert ($result.Contains('已取消') -and ([IO.File]::ReadAllText($locationRecord) | ConvertFrom-Json).path -ceq $install -and
    [IO.File]::ReadAllText($env:fixtureRunFile) -ceq $oldStartup -and -not (Test-Path -LiteralPath $install)) 'Cancel after uninstall changed the location or enabled startup'
$env:fixtureChoice = $parkedInstall
$recoveryManifest = [IO.File]::ReadAllText($manifestPath)
$null = New-Bundle '0.6.0-beta.9' -BadHash
$result = Run-Launcher $launcherPath -Fail
Assert ($result.Contains('ZIP 校验失败') -and [IO.File]::ReadAllText($env:fixtureRunFile) -ceq $oldStartup -and
    ([IO.File]::ReadAllText($locationRecord) | ConvertFrom-Json).previousPath -ceq $install -and
    -not (Test-Path -LiteralPath (Join-Path $fixture 'fixture-registry-write.log'))) 'A failed recovered installation changed startup or forgot the pending previous location'
Write-Fixture $manifestPath $recoveryManifest
$pickerCountBeforeRetry = (Get-Content -LiteralPath $pickerLog).Count
$env:fixtureChoice = 'cancel'
$null = Run-Launcher $launcherPath
Assert (([IO.File]::ReadAllText($locationRecord) | ConvertFrom-Json).path -ceq $parkedInstall -and
    -not ([IO.File]::ReadAllText($locationRecord) | ConvertFrom-Json).PSObject.Properties['previousPath'] -and
    (Get-Content -LiteralPath $pickerLog).Count -eq $pickerCountBeforeRetry -and
    [IO.File]::ReadAllText((Join-Path $parkedInstall '.state/fixture-private-settings.json')) -ceq 'preserve this' -and
    [IO.File]::ReadAllText($env:fixtureRunFile).Contains((Join-Path $parkedInstall 'Launch-Workshop.ps1')) -and
    (Get-Content -LiteralPath (Join-Path $fixture 'fixture-registry-write.log')).Count -eq 1) 'Recovery lost the selected account or did not update the exact enabled startup entry after success'

# 再次移走当前安装，明确确认同一旧路径后才在原位置重建新安装。
$recordBeforeRebuild = [IO.File]::ReadAllText($locationRecord)
$preservedInstall = Join-Path $fixture '保留的账号副本'
[IO.Directory]::Move($parkedInstall, $preservedInstall)
$startupBeforeRebuild = [IO.File]::ReadAllText($env:fixtureRunFile)
$env:fixtureChoice = 'cancel'
$null = Run-Launcher $launcherPath
Assert ([IO.File]::ReadAllText($locationRecord) -ceq $recordBeforeRebuild -and [IO.File]::ReadAllText($env:fixtureRunFile) -ceq $startupBeforeRebuild) 'Cancelling a rebuild changed saved settings'
$env:fixtureChoice = $parkedInstall
$null = Run-Launcher $launcherPath
Assert (Test-Path -LiteralPath (Join-Path $parkedInstall '.state/fixture-start.log')) 'Explicitly confirming the removed directory did not reinstall'
Assert ([IO.File]::ReadAllText((Join-Path $preservedInstall '.state/fixture-private-settings.json')) -ceq 'preserve this' -and
    [IO.File]::ReadAllText($env:fixtureRunFile) -ceq $startupBeforeRebuild) 'Rebuilding migrated the old account or unnecessarily changed startup'

$newDefaultData = Join-Path $fixture '默认用户'
$newDefault = Join-Path $newDefaultData 'Zcc/DST-Music/Workshop/3836261433'
$newDefaultLocation = Join-Path $newDefault 'install-location.json'
Set-FixtureLauncher $newDefaultData
[IO.File]::Delete($lua)
$env:fixtureChoice = 'default'
$result = Run-Launcher $launcherPath
Assert ($result.Contains($newDefault) -and (Test-Path -LiteralPath (Join-Path $newDefault '.state/fixture-start.log')) -and
    (([IO.File]::ReadAllText($newDefaultLocation) | ConvertFrom-Json).path -ceq $newDefault)) 'Accepting the default did not install and remember the original path'

# 保留标记、包清单和状态，模拟尚无位置记录的旧版安装。
[IO.File]::Delete($newDefaultLocation)
$legacySettings = Join-Path $newDefault '.state/fixture-private-settings.json'
Write-Fixture $legacySettings 'legacy account and settings'
$legacyLauncher = Join-Path $newDefault 'Launch-Workshop.ps1'
$null = Run-Launcher $legacyLauncher @('-AutoStart')
$null = Run-Launcher $legacyLauncher @('-Stop')
$pickerCount = (Get-Content -LiteralPath $pickerLog).Count
$env:fixtureChoice = 'cancel'
$null = New-Bundle '0.6.0-beta.8'
$result = Run-Launcher $launcherPath
$null = Run-Launcher $legacyLauncher @('-AutoStart')
Assert ($result.Contains($newDefault) -and (Get-Content -LiteralPath $pickerLog).Count -eq $pickerCount -and
    [IO.File]::ReadAllText($legacySettings) -ceq 'legacy account and settings' -and
    ((Get-ChildItem -LiteralPath (Join-Path $newDefault 'versions') -Directory).Count -eq 2)) 'A preexisting default installation did not retain its location, versions or state on upgrade'

$lockPath = Join-Path $newDefault 'launcher.lock'
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $result = Run-Launcher $launcherPath -Fail
    Assert ($result.Contains('播放器启动器正在运行')) 'Concurrent launches bypassed the install lock'
} finally { $lock.Dispose() }
Write-Output ('PASS cancel, default, custom path, remember, exact Mod, shared state, reuse, upgrade, rollback, registry stubs, stop, corrupt record rejection, missing directory recovery/cancel/rebuild, chosen account preservation, enabled startup follows only after success, legacy default, concurrent launch, checksum and ZIP traversal rejection. Fixture: ' + $fixture)
