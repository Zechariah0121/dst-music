$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$game = Join-Path $fixture "Steam 库/steamapps/common/Don't Starve Together"
$workshop = Join-Path $fixture 'Steam 库/steamapps/workshop/content/322330/3836261433'
$launcherDir = Join-Path $workshop 'windows-player'
$localData = Join-Path $fixture '户'
$install = Join-Path $localData 'Zcc/DST-Music/Workshop/3836261433'
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
$launcher = [IO.File]::ReadAllText((Join-Path $root 'release/workshop/Launch-Workshop.ps1'))
# Replace only the two OS dependencies in the isolated launcher copy.
$launcher = $launcher.Replace('[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)', "'" + $localData.Replace("'", "''") + "'")
$launcher = $launcher.Replace('[Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port -contains 17863', '(Test-Path -LiteralPath (Join-Path $stateDir ''fixture-port-busy''))')
Write-Fixture $launcherPath $launcher

$zip = New-Bundle '0.6.0-beta.1'
$result = Run-Launcher $launcherPath
$lua = Join-Path $workshop 'scripts/dangomusic_connection.lua'
Assert (Test-Path -LiteralPath $lua -PathType Leaf) 'First launch did not connect the precise subscribed Mod'
Assert (Test-Path -LiteralPath (Join-Path $state 'fixture-start.log') -PathType Leaf) 'First launch did not start the companion'
Assert ($result.Contains('ESC')) 'First launch omitted in-game connection guidance'
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

# Load the real registry helper functions into a scope that replaces registry
# commands with memory-backed stubs. The actual HKCU Run key is untouched.
& {
    . (Join-Path $root 'Runtime-Paths.ps1')
    $installDir = $install
    $versionsDir = Join-Path $install 'versions'
    $currentPath = Join-Path $install 'current.json'
    $runKey = 'Fixture:/Run'
    $runName = 'ZccDSTMusic'
    $script:fixtureRunEntry = $null
    $tokens = $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$parseErrors)
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
Write-Output ('PASS first launch, exact Mod, shared state, reuse, upgrade, rollback, opt-in autostart with registry stubs, stop, checksum and ZIP traversal rejection. Fixture: ' + $fixture)
