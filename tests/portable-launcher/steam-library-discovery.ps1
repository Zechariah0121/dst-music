param([string]$RuntimePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $RuntimePath) { $RuntimePath = Join-Path $root 'Runtime-Paths.ps1' }
. $RuntimePath
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('music-steam-discovery-' + [guid]::NewGuid().ToString('N'))
# Include spaces and non-ASCII text without depending on the test file encoding.
$library = Join-Path $fixture ('Steam ' + [char]0x4E2D + [char]0x6587 + ' Library')
$game = Join-Path $library "steamapps/common/Don't Starve Together"
$modern = Join-Path $library 'steamapps/workshop/content/322330/3836261433'
$script:registrySteamPath = $library.ToLowerInvariant().Replace('\','/')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    if ($LiteralPath -ne 'HKCU:/Software/Valve/Steam' -or $Name -ne 'SteamPath') { throw 'Unexpected registry read' }
    return [pscustomobject]@{SteamPath=$script:registrySteamPath}
}
function New-Game([string]$GameDir) {
    New-Item -ItemType Directory -Path (Join-Path $GameDir 'data/databundles') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $GameDir 'data/databundles/scripts.zip'), 'fixture')
}
function New-Mod([string]$ModDir) {
    New-Item -ItemType Directory -Path (Join-Path $ModDir 'scripts') -Force | Out-Null
    foreach ($name in @('modinfo.lua','modmain.lua')) { [IO.File]::WriteAllText((Join-Path $ModDir $name), '-- fixture') }
    [IO.File]::WriteAllText((Join-Path $ModDir 'music_workshop_identity.json'), '{"schema":1,"id":"zcc-dst-music","channel":"workshop-beta","version":"path-regression"}')
}
function Set-Libraries([string[]]$Paths) {
    $entries = @()
    for ($i=0; $i -lt $Paths.Count; $i++) { $entries += '"' + $i + '" { "path" "' + $Paths[$i].Replace('\','\\') + '" }' }
    [IO.File]::WriteAllText((Join-Path $library 'steamapps/libraryfolders.vdf'), ('"libraryfolders" { ' + ($entries -join ' ') + ' }'), (New-Object Text.UTF8Encoding($false)))
}
function Snapshot {
    return ((Get-ChildItem -LiteralPath $fixture -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n")
}
function Assert-Ambiguous {
    $message = ''
    try { $null = Find-MusicWorkshopConnection } catch { $message = $_.Exception.Message }
    Assert ($message -match '\b2\b' -and $message.Contains('Connect-Workshop.ps1')) 'Two distinct Mods must still require an explicit selection'
}
New-Game $game
New-Mod $modern
$aliases = @($library, ($library.ToUpperInvariant() + '\'), ($script:registrySteamPath + '/./'))
Set-Libraries $aliases
$before = Snapshot
$libraries = @(Get-MusicSteamLibraries)
Assert ($libraries.Count -eq 1) ('Same library discovered ' + $libraries.Count + ' times')
$connection = Find-MusicWorkshopConnection
Assert ($connection.gameDir -ieq $game -and $connection.modDir -ieq $modern) 'Automatic discovery did not select the only physical Mod'
Assert ((Snapshot) -ceq $before) 'Discovery modified fixture files'
Write-Output 'PASS registry/VDF case, slash, dot, trailing-separator aliases select one modern Mod; no file writes'

$unusedDrive = 'Z','Y','X','W','V','U','T' | Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
if ($unusedDrive) {
    $missingLibrary = $unusedDrive + ':\Missing Steam Library'
    Set-Libraries (@($missingLibrary) + $aliases)
    $connection = Find-MusicWorkshopConnection
    Assert ($connection.modDir -ieq $modern) 'Stale drive in Steam libraryfolders.vdf blocked the available library'
    Set-Libraries $aliases
    Write-Output 'PASS missing Steam library drive is skipped'
}

$driveRoot = [IO.Path]::GetPathRoot($library)
$roots = @(Get-MusicUniquePaths @($driveRoot, $driveRoot.ToLowerInvariant().Replace('\','/')))
Assert ($roots.Count -eq 1 -and $roots[0] -ieq $driveRoot) 'Drive root was duplicated or changed into a drive-relative path'
Assert (@(Get-MusicUniquePaths @()).Count -eq 0) 'Empty discovery produced a path'
Write-Output 'PASS drive-root and empty-path-list normalization'

# Simulate overlapping discovery roots: the final Mod candidate list must also deduplicate.
$script:originalRoots = ${function:Get-MusicWorkshopRoots}
function Get-MusicWorkshopRoots([string]$GameDir) {
    $normal = @(& $script:originalRoots $GameDir)
    return @($normal) + @($normal | ForEach-Object { $_.ToUpperInvariant() })
}
$connection = Find-MusicWorkshopConnection
Assert ($connection.modDir -ieq $modern) 'Overlapping roots double-counted a single Mod'
$legacy = Join-Path $game 'mods/workshop-3836261433'
New-Mod $legacy
Assert-Ambiguous
$legacyAlias = Join-Path ((Split-Path $legacy -Parent).ToUpperInvariant()) (Split-Path $legacy -Leaf)
$connection = Find-MusicWorkshopConnection -GamePath $game.ToUpperInvariant() -ModPath $legacyAlias
Assert ($connection.modDir -ieq $legacy) 'Explicit Mod selection failed with mixed case'
Write-Output 'PASS overlapping roots deduplicate; distinct legacy and modern copies remain ambiguous; explicit selection works'

# Restore the real root helper, then exercise duplicate game inputs independently of library deduplication.
. $RuntimePath
function Get-MusicSteamLibraries { return @($library.ToLowerInvariant(), $library.ToUpperInvariant()) }
$script:resolveCalls = 0
$script:originalResolve = ${function:Resolve-MusicGamePath}
function Resolve-MusicGamePath([string]$Path) { $script:resolveCalls++; & $script:originalResolve $Path }
Assert-Ambiguous
# One game resolution plus one resolution for each of its two valid Mods.
Assert ($script:resolveCalls -eq 3) 'Game discovery scanned the same game more than once'
Write-Output 'PASS repeated game paths are scanned once'

. $RuntimePath
$otherLibrary = Join-Path $fixture 'Other Steam Library'
$otherGame = Join-Path $otherLibrary "steamapps/common/Don't Starve Together"
$otherMod = Join-Path $otherGame 'mods/workshop-3836261433'
New-Game $otherGame
New-Mod $otherMod
Set-Libraries @($library, $otherLibrary)
# Keep only one identified Mod in the first library, without deleting any fixture.
Move-Item -LiteralPath (Join-Path $legacy 'music_workshop_identity.json') -Destination (Join-Path $legacy 'identity.disabled')
$before = Snapshot
Assert (@(Get-MusicSteamLibraries).Count -eq 2) 'Different libraries were merged'
Assert-Ambiguous
$connection = Find-MusicWorkshopConnection -GamePath $otherGame
Assert ($connection.modDir -ieq $otherMod) 'Explicit game selection did not find its legacy Mod'
Assert ((Snapshot) -ceq $before) 'Multi-library discovery modified fixture files'
Write-Output 'PASS distinct libraries remain separate; explicit game selection finds legacy layout; no file writes'

# Exercise the retained local installer entry point against the same aliases.
Set-Libraries $aliases
if ($unusedDrive) { Set-Libraries (@($missingLibrary) + $aliases) }
$package = Join-Path $fixture 'Player Fixture'
New-Item -ItemType Directory -Path (Join-Path $package 'mod/scripts'),(Join-Path $package 'mod/images') -Force | Out-Null
foreach ($name in @('modinfo.lua','modmain.lua')) { [IO.File]::WriteAllText((Join-Path $package ('mod/' + $name)), '-- fixture') }
Copy-Item -LiteralPath $RuntimePath -Destination (Join-Path $package 'Runtime-Paths.ps1')
Copy-Item -LiteralPath (Join-Path (Split-Path $RuntimePath -Parent) 'Install-Mod.ps1') -Destination $package
$registryStub = "`r`nfunction Get-ItemProperty { return @{SteamPath='" + $script:registrySteamPath.Replace("'", "''") + "'} }`r`n"
[IO.File]::AppendAllText((Join-Path $package 'Runtime-Paths.ps1'), $registryStub, (New-Object Text.UTF8Encoding($false)))
$ps = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$output = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Install-Mod.ps1')
Assert ($LASTEXITCODE -eq 0) 'Local installer automatic discovery failed'
$installed = Get-Content -LiteralPath (Join-Path $package '.state/install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($installed.gameDir -ieq $game -and $installed.modDir -ieq (Join-Path $game 'mods/local_netease_music')) 'Local installer selected a different game'
Write-Output 'PASS local installer automatic discovery accepts one physical game with multiple path spellings'
Write-Output ('PASS all Steam path discovery regressions. Fixture: ' + $fixture)
