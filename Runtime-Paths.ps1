function Assert-MusicSafePath([string]$Path, [switch]$Tree) {
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    $rootAttributes = $null
    while ($current) {
        $attributes = $null
        # Windows can still report attributes for a DeleteOnClose PCM file
        # while PowerShell's filesystem provider denies a lookup by name.
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {}
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw '路径包含 junction 或符号链接，已停止。'
        }
        if ($current -eq $full) { $rootAttributes = $attributes }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
    if ($Tree -and ($rootAttributes -band [IO.FileAttributes]::Directory)) {
        foreach ($item in ([IO.DirectoryInfo]::new($full)).EnumerateFileSystemInfos()) {
            Assert-MusicSafePath $item.FullName -Tree:($item -is [IO.DirectoryInfo])
        }
    }
}

function Get-MusicRuntime {
    $root = $PSScriptRoot
    $node = Join-Path $root 'runtime/node/node.exe'
    $python = Join-Path $root 'runtime/python/python.exe'
    foreach ($file in @($node, $python)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw '包内运行库缺失，请重新解压完整发行包（runtime 目录）。' }
    }
    $version = & $node --version
    $validVersion = [string]$version -match '^v([0-9]+)\.[0-9]+\.[0-9]+'
    if ($LASTEXITCODE -ne 0 -or -not $validVersion -or [int]$Matches[1] -lt 22) { throw '包内 Node.js 运行库无效，需要 22 或更新版本。' }
    & $python -I -c 'import sys, PIL; assert sys.version_info >= (3, 10)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '包内 Python 或 Pillow 运行库无效。' }
    return @{ Node = $node; Python = $python }
}

function Read-MusicConnection([string]$Path) {
    try { $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw '本机 bridge.json 配置无法读取。' }
    if ($config.host -cne '127.0.0.1' -or $config.port -isnot [ValueType] -or $config.port -ne 17863 -or
        $config.token -isnot [string] -or $config.token -cnotmatch '^[a-zA-Z0-9_-]{24,128}$') {
        throw '本机连接配置无效，请检查 host、port 和 token。'
    }
    return $config
}

function Test-MusicProcess($Record, [string]$Script) {
    if (-not $Record -or $Record.script -ne $Script -or -not $Record.executable) { return $false }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$Record.pid)"
    if (-not $process -or $process.ExecutablePath -ne $Record.executable -or
        -not $process.CommandLine -or -not $process.CommandLine.Contains('"' + $Script + '"')) { return $false }
    if ($Record.created -and $process.CreationDate.ToUniversalTime().ToString('o') -ne $Record.created) { return $false }
    return $true
}


function Write-MusicText([string]$Path, [string]$Text) {
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Get-MusicUniquePaths([string[]]$Paths) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        $full = [IO.Path]::GetFullPath($path)
        # Preserve drive/UNC roots: trimming C:\ to C: makes the path relative.
        $root = [IO.Path]::GetPathRoot($full)
        if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\','/') }
        if ($seen.Add($full)) { $full }
    }
}

function Get-MusicSteamLibraries {
    $steamPath = (Get-ItemProperty -LiteralPath 'HKCU:/Software/Valve/Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    $libraries = @()
    if ($steamPath -and (Test-Path -LiteralPath $steamPath -PathType Container)) {
        $libraries += $steamPath
        $libraryFile = Join-Path $steamPath 'steamapps/libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
            Assert-MusicSafePath $libraryFile
            $text = Get-Content -LiteralPath $libraryFile -Raw -Encoding UTF8
            $libraries += [regex]::Matches($text, '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.Replace('\\','\') }
        }
    }
    return @(Get-MusicUniquePaths $libraries | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

function Get-MusicSteamGamePaths {
    $paths = @(Get-MusicSteamLibraries | ForEach-Object {
        [IO.Path]::Combine($_, "steamapps/common/Don't Starve Together")
    } | Where-Object {
        Test-Path -LiteralPath ([IO.Path]::Combine($_, 'data/databundles/scripts.zip')) -PathType Leaf
    })
    return @(Get-MusicUniquePaths $paths)
}

function Resolve-MusicGamePath([string]$Path) {
    Assert-MusicSafePath $Path
    $gameDir = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $scripts = Join-Path $gameDir 'data/databundles/scripts.zip'
    Assert-MusicSafePath $scripts
    if (-not (Test-Path -LiteralPath $scripts -PathType Leaf)) { throw '指定目录不是 DST 游戏安装目录。' }
    return $gameDir
}

function Get-MusicWorkshopRoots([string]$GameDir) {
    $roots = @((Join-Path $GameDir 'mods'))
    $commonDir = Split-Path $GameDir -Parent
    $steamAppsDir = Split-Path $commonDir -Parent
    if ((Split-Path $commonDir -Leaf) -ieq 'common' -and (Split-Path $steamAppsDir -Leaf) -ieq 'steamapps') {
        $roots += Join-Path $steamAppsDir 'workshop/content/322330'
    }
    return $roots
}

function Assert-MusicWorkshopMod([string]$ModDir, [string]$GameDir) {
    $modPath = [IO.Path]::GetFullPath($ModDir).TrimEnd('\','/')
    $gamePath = Resolve-MusicGamePath $GameDir
    $parent = Split-Path $modPath -Parent
    $name = Split-Path $modPath -Leaf
    $roots = @(Get-MusicWorkshopRoots $gamePath)
    $legacy = $parent -ieq $roots[0] -and $name -cmatch '^workshop-[1-9][0-9]*$'
    $modern = $roots.Count -gt 1 -and $parent -ieq $roots[1] -and $name -cmatch '^[1-9][0-9]*$'
    if (-not ($legacy -or $modern)) { throw '工坊目录与指定游戏不匹配，必须位于该游戏的 mods/workshop-ID 或同一 Steam 库的 workshop/content/322330/ID。' }
    Assert-MusicSafePath $modPath -Tree
    $marker = Join-Path $modPath 'music_workshop_identity.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw '工坊 Mod 缺少 music_workshop_identity.json 身份文件。' }
    try { $identity = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw '工坊 Mod 身份文件无法读取。' }
    $properties = @($identity.PSObject.Properties.Name)
    $unknownProperties = @($properties | Where-Object { $_ -cnotin @('schema','id','channel','version') })
    if (-not $identity -or
        $unknownProperties.Count -gt 0 -or
        ('version' -cin $properties -and $identity.version -isnot [string]) -or
        ($identity.schema -isnot [int] -and $identity.schema -isnot [long]) -or $identity.schema -ne 1 -or
        $identity.id -cne 'zcc-dst-music' -or $identity.channel -cne 'workshop-beta') {
        throw '工坊 Mod 身份文件不匹配，已停止连接。'
    }
    foreach ($file in @('modinfo.lua','modmain.lua')) {
        if (-not (Test-Path -LiteralPath (Join-Path $modPath $file) -PathType Leaf)) { throw '工坊 Mod 文件不完整，请等待 Steam 完成下载。' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $modPath 'scripts') -PathType Container)) { throw '工坊 Mod scripts 目录缺失，请等待 Steam 完成下载。' }
    return $modPath
}

function Find-MusicWorkshopConnection([string]$GamePath, [string]$ModPath) {
    if ($ModPath -and -not $GamePath) {
        $fullMod = [IO.Path]::GetFullPath($ModPath).TrimEnd('\','/')
        $parent = Split-Path $fullMod -Parent
        if ((Split-Path $parent -Leaf) -ieq 'mods') { $GamePath = Split-Path $parent -Parent }
        elseif ((Split-Path $parent -Leaf) -ceq '322330') {
            $content = Split-Path $parent -Parent
            $workshop = Split-Path $content -Parent
            $steamApps = Split-Path $workshop -Parent
            if ((Split-Path $content -Leaf) -ieq 'content' -and (Split-Path $workshop -Leaf) -ieq 'workshop' -and (Split-Path $steamApps -Leaf) -ieq 'steamapps') {
                $GamePath = Join-Path $steamApps "common/Don't Starve Together"
            }
        }
        if (-not $GamePath) { throw '无法从工坊目录确定游戏，请同时指定 -GamePath。' }
    }
    if ($GamePath) { $games = @(Resolve-MusicGamePath $GamePath) }
    else {
        $games = @(Get-MusicSteamGamePaths)
    }
    if ($ModPath) { return @{gameDir=$games[0]; modDir=(Assert-MusicWorkshopMod $ModPath $games[0])} }
    $candidates = @()
    $seenMods = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($game in $games) {
        $game = Resolve-MusicGamePath $game
        foreach ($root in @(Get-MusicWorkshopRoots $game)) {
            Assert-MusicSafePath $root
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
                if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'music_workshop_identity.json') -PathType Leaf)) { continue }
                try { $validMod = Assert-MusicWorkshopMod $dir.FullName $game }
                catch { continue }
                if ($seenMods.Add($validMod)) { $candidates += @{gameDir=$game;modDir=$validMod} }
            }
        }
    }
    if ($candidates.Count -ne 1) { throw ('找到 ' + $candidates.Count + ' 个符合身份的工坊 Mod，无法唯一确定。请使用 Connect-Workshop.ps1 -GamePath 和 -ModPath 指定目录。') }
    return $candidates[0]
}

function New-MusicConnection {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return @{host='127.0.0.1';port=17863;token=([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()}
}

function Write-MusicModConnection([string]$ModDir, $Config) {
    $luaPath = Join-Path $ModDir 'scripts/dangomusic_connection.lua'
    Assert-MusicSafePath $luaPath
    $text = 'return {host="127.0.0.1",port=17863,token="' + $Config.token + '"}' + "`n"
    if (-not (Test-Path -LiteralPath $luaPath) -or (Get-Content -LiteralPath $luaPath -Raw -Encoding UTF8) -cne $text) { Write-MusicText $luaPath $text }
}

function Read-MusicInstallation([string]$Path) {
    try { $installed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw '安装记录无法读取，请重新安装客户端 Mod 或连接工坊 Mod。' }
    if (-not $installed.gameDir -or -not $installed.modDir) { throw '安装记录缺少游戏或 Mod 路径。' }
    $game = Resolve-MusicGamePath $installed.gameDir
    if ($installed.mode -ceq 'workshop') { $mod = Assert-MusicWorkshopMod $installed.modDir $game }
    elseif (-not $installed.mode -or $installed.mode -ceq 'local') {
        $mod = [IO.Path]::GetFullPath($installed.modDir).TrimEnd('\','/')
        Assert-MusicSafePath $mod -Tree
        $marker = Join-Path $mod 'music_bridge_owned.txt'
        if ($mod -ine (Join-Path $game 'mods/local_netease_music') -or
            -not (Test-Path -LiteralPath $marker -PathType Leaf) -or
            (Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim() -cne 'dst-local-music-prototype-v1') { throw '安装记录无效，请重新安装客户端 Mod。' }
    } else { throw '安装记录 mode 无效，请重新安装客户端 Mod 或连接工坊 Mod。' }
    return @{mode=$installed.mode;gameDir=$game;modDir=$mod}
}

function Assert-MusicServiceConnectionTarget([string]$StateDir, [string]$ModDir, [string]$FontsPath, [switch]$AllowLegacy) {
    $recordPath = Join-Path $StateDir 'process.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return }
    try { $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw '服务进程记录无法读取，请检查 .state/process.json。' }
    if (-not (Test-MusicProcess $record (Join-Path $PSScriptRoot 'helper/server.mjs'))) { return }
    if ($AllowLegacy -and -not $record.runtimeModDir -and -not $record.fontsPath) {
        try {
            $installed = Read-MusicInstallation (Join-Path $StateDir 'install.json')
            if ($installed.mode -cne 'workshop' -and $installed.modDir -ieq $ModDir -and
                (Join-Path $installed.gameDir 'data/databundles/fonts.zip') -ieq $FontsPath) { return }
        } catch {}
    }
    if ($record.runtimeModDir -ine $ModDir -or $record.fontsPath -ine $FontsPath) {
        throw '当前播放器服务使用其他 Mod 目录或旧版进程记录。请先双击停止播放器，再执行安装或连接并重新启动。'
    }
}



