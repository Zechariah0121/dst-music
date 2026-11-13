param([switch]$AutoStart, [switch]$Settings, [switch]$Stop)

$ErrorActionPreference = 'Stop'
$workshopId = '3836261433'
$runKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run'
$runName = 'ZccDSTMusic'

function Get-CompanionPackage($Manifest) {
    if ($Manifest.schema -ne 1 -or
        $Manifest.package -isnot [string] -or
        $Manifest.package -cnotmatch '^DST-Music-[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.]+)?-Windows-Companion$' -or
        $Manifest.sha256 -isnot [string] -or $Manifest.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw '播放器包清单无效。请在 Steam 中重新下载此模组。'
    }
    return ($Manifest.package + '-' + $Manifest.sha256.Substring(0, 16))
}

function Read-CompanionManifest([string]$Path) {
    Assert-MusicSafePath $Path
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw '无法读取播放器包清单。请确认 Steam 已下载完整模组。' }
}

function Get-InstalledCompanion($Manifest, [switch]$CheckFiles) {
    $directory = Join-Path $versionsDir (Get-CompanionPackage $Manifest)
    Assert-MusicSafePath $directory
    if (-not (Test-Path -LiteralPath $directory)) { return }
    $stamp = Read-CompanionManifest (Join-Path $directory 'workshop-package.json')
    if ($stamp.package -cne $Manifest.package -or $stamp.sha256 -cne $Manifest.sha256) {
        throw '已存在同名的播放器安装目录。请检查本机播放器目录后重试。'
    }
    if ($CheckFiles) { Assert-CompanionFiles $directory }
    return $directory
}

function Assert-CompanionFiles([string]$Directory) {
    foreach ($name in @('Start-Player.ps1','Stop-Player.ps1','Connect-Workshop.ps1','Check-Environment.ps1','Runtime-Paths.ps1','helper/server.mjs','helper/NativePlayer.ps1','runtime/node/node.exe','runtime/python/python.exe')) {
        $path = Join-Path $Directory $name
        Assert-MusicSafePath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw '播放器文件不完整。请检查本机播放器目录或重新下载工坊模组。'
        }
    }
}

function Install-Companion($Manifest, [string]$ArchivePath) {
    Assert-MusicSafePath $ArchivePath
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw '找不到配套播放器 ZIP。请确认 Steam 已下载完整模组。'
    }
    $destination = Join-Path $versionsDir (Get-CompanionPackage $Manifest)
    $temporary = Join-Path $versionsDir ('.extract-' + [guid]::NewGuid().ToString('N'))
    Add-Type -AssemblyName System.IO.Compression
    Write-Output '正在校验并解压配套播放器…' | Out-Host
    try {
        $file = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try { $digest = [BitConverter]::ToString($algorithm.ComputeHash($file)).Replace('-', '').ToLowerInvariant() }
            finally { $algorithm.Dispose() }
            if ($digest -cne $Manifest.sha256) { throw '播放器 ZIP 校验失败。请在 Steam 中重新下载此模组。' }
            $file.Position = 0
            $archive = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                [IO.Directory]::CreateDirectory($temporary) | Out-Null
                $prefix = $Manifest.package + '/'
                foreach ($entry in $archive.Entries) {
                    $name = $entry.FullName
                    if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal)) {
                        throw '播放器 ZIP 的文件路径无效。请重新下载模组。'
                    }
                    $relative = $name.Substring($prefix.Length)
                    foreach ($part in $relative.Split('/')) {
                        if ($part.Length -eq 0 -or $part -match '[\\:\x00-\x1f<>|?*"]|[. ]$|^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9¹²³]|LPT[0-9¹²³])(?:\.|$)' -or
                            $part -in @('.state', 'workshop-package.json', 'dangomusic_connection.lua')) {
                            throw '播放器 ZIP 的文件路径无效。请重新下载模组。'
                        }
                    }
                    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($temporary, $relative))
                    if (-not $path.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                        throw '播放器 ZIP 的文件路径超出了安装目录。请重新下载模组。'
                    }
                    Assert-MusicSafePath $path
                    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
                    $inputStream = $entry.Open()
                    try {
                        $outputStream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
                    } finally { $inputStream.Dispose() }
                }
            } finally { $archive.Dispose() }
        } finally { $file.Dispose() }
        Assert-CompanionFiles $temporary
        Write-MusicText (Join-Path $temporary 'workshop-package.json') ($Manifest | ConvertTo-Json)
        [IO.Directory]::Move($temporary, $destination)
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            $resolved = [IO.Path]::GetFullPath((Get-Item -LiteralPath $temporary -Force).FullName)
            if ((Split-Path $resolved -Parent) -ieq $versionsDir -and (Split-Path $resolved -Leaf) -match '^\.extract-[a-f0-9]{32}$') {
                Assert-MusicSafePath $resolved -Tree
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
    }
    return $destination
}

function Get-AutoStartCommand {
    $powershell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    return ('"' + $powershell + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installDir 'Launch-Workshop.ps1') + '" -AutoStart')
}

function Get-AutoStartEntry {
    if (-not (Test-Path -LiteralPath $runKey)) { return }
    $key = Get-Item -LiteralPath $runKey
    try {
        if ($key.GetValueNames() -contains $runName) {
            return @{
                kind = $key.GetValueKind($runName)
                value = $key.GetValue($runName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
    } finally { $key.Dispose() }
}

function Set-AutoStart([bool]$Enabled) {
    $command = Get-AutoStartCommand
    $existing = Get-AutoStartEntry
    if ($existing -and ($existing.kind -ne [Microsoft.Win32.RegistryValueKind]::String -or $existing.value -cne $command)) {
        throw 'Windows 中已有同名启动项。请先在系统的启动设置里检查它。'
    }
    if ($Enabled -and -not $existing) {
        if ($command.Length -gt 260) { throw 'Windows 用户目录过长，无法启用随 Windows 启动。仍可双击启动播放器。' }
        Assert-MusicSafePath $currentPath
        $stableLauncher = Join-Path $installDir 'Launch-Workshop.ps1'
        Assert-MusicSafePath $stableLauncher
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $stableLauncher -PathType Leaf) -or
            -not (Get-InstalledCompanion (Read-CompanionManifest $currentPath) -CheckFiles)) {
            throw '请先双击「一键启动播放器」完成安装。'
        }
        if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
        New-ItemProperty -LiteralPath $runKey -Name $runName -PropertyType String -Value $command | Out-Null
    } elseif (-not $Enabled -and $existing) {
        Remove-ItemProperty -LiteralPath $runKey -Name $runName
    }
}

function Show-AutoStartSettings {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = [Windows.Forms.Form]::new()
    try {
        $form.Text = '云间音乐 · 自启动设置'
        $form.ClientSize = [Drawing.Size]::new(410, 145)
        $form.FormBorderStyle = 'FixedDialog'
        $form.StartPosition = 'CenterScreen'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $check = [Windows.Forms.CheckBox]::new()
        $check.Text = '登录 Windows 后启动本机播放器'
        $check.SetBounds(22, 23, 360, 25)
        $existing = Get-AutoStartEntry
        $check.Checked = $existing -and $existing.kind -eq [Microsoft.Win32.RegistryValueKind]::String -and $existing.value -ceq (Get-AutoStartCommand)
        $hint = [Windows.Forms.Label]::new()
        $hint.Text = '保存后生效。可以在这里随时关闭。'
        $hint.SetBounds(24, 52, 365, 25)
        $save = [Windows.Forms.Button]::new()
        $save.Text = '保存'
        $save.DialogResult = 'OK'
        $save.SetBounds(215, 95, 75, 28)
        $cancel = [Windows.Forms.Button]::new()
        $cancel.Text = '取消'
        $cancel.DialogResult = 'Cancel'
        $cancel.SetBounds(305, 95, 75, 28)
        $form.Controls.AddRange(@($check, $hint, $save, $cancel))
        $form.AcceptButton = $save
        $form.CancelButton = $cancel
        if ($form.ShowDialog() -eq 'OK') { Set-AutoStart $check.Checked }
    } finally { $form.Dispose() }
}

function Test-CompanionEnvironment([string]$Directory) {
    $powershell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $ErrorActionPreference = 'Continue'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Directory 'Start-Player.ps1') -CheckOnly 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '配套播放器环境检查失败。请重新下载模组，并确认 Windows PowerShell 5.1 和 .NET Framework 可用。' }
}

try {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localData) { throw 'Windows 无法找到本机应用数据目录。' }
    $installDir = [IO.Path]::GetFullPath((Join-Path $localData ('Zcc/DST-Music/Workshop/' + $workshopId)))
    $versionsDir = Join-Path $installDir 'versions'
    $stateDir = Join-Path $installDir '.state'
    $currentPath = Join-Path $installDir 'current.json'
    $ownershipPath = Join-Path $installDir 'bootstrap.id'
    . (Join-Path $PSScriptRoot 'Runtime-Paths.ps1')
    Assert-MusicSafePath $installDir
    if ($Settings) { Show-AutoStartSettings; return }

    if ($AutoStart -or $Stop) {
        if ($AutoStart -and $PSScriptRoot -ine $installDir) { throw '请从已安装的播放器目录运行此选项。' }
        if (-not (Test-Path -LiteralPath $installDir -PathType Container)) { throw '请先双击工坊目录里的「一键启动播放器」。' }
        Assert-MusicSafePath $versionsDir
    } else {
        $workshopPath = Split-Path $PSScriptRoot -Parent
        $modName = Split-Path $workshopPath -Leaf
        if ($modName -cnotin @($workshopId, ('workshop-' + $workshopId))) {
            throw '请在 Steam 下载的本模组目录里双击「一键启动播放器」。'
        }
        $connection = Find-MusicWorkshopConnection -ModPath $workshopPath
        $manifest = Read-CompanionManifest (Join-Path $PSScriptRoot 'companion.json')
        $null = Get-CompanionPackage $manifest
        Assert-MusicSafePath $versionsDir
        [IO.Directory]::CreateDirectory($versionsDir) | Out-Null
    }

    $lockPath = Join-Path $installDir 'launcher.lock'
    Assert-MusicSafePath $lockPath
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw '播放器启动器正在运行，请等当前操作完成后再试。' }
    try {
        $previous = $null
        Assert-MusicSafePath $currentPath
        if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
            try { $previous = Get-InstalledCompanion (Read-CompanionManifest $currentPath) }
            catch {
                if ($AutoStart -or $Stop) { throw }
                Write-Output '上次的安装记录无法使用，正在检查当前工坊包。'
            }
        }
        if ($AutoStart -or $Stop) {
            if (-not $previous) { throw '请先双击工坊目录里的「一键启动播放器」。' }
            if ($Stop) {
                Assert-MusicSafePath (Join-Path $previous 'Stop-Player.ps1')
                & (Join-Path $previous 'Stop-Player.ps1') -StateDir $stateDir
            } else {
                Assert-CompanionFiles $previous
                & (Join-Path $previous 'Start-Player.ps1') -StateDir $stateDir -NoBrowser
            }
            return
        }

        $directory = Get-InstalledCompanion $manifest -CheckFiles
        if (-not $directory) {
            $directory = Install-Companion $manifest (Join-Path $PSScriptRoot ($manifest.package + '.zip'))
        }
        $stableLauncher = Join-Path $installDir 'Launch-Workshop.ps1'
        $stablePaths = Join-Path $installDir 'Runtime-Paths.ps1'
        $stableSettings = Join-Path $installDir '自启动设置.cmd'
        $stableStop = Join-Path $installDir '停止配套播放器.cmd'
        $ownershipId = 'zcc-dst-music-workshop-launcher-v1'
        Assert-MusicSafePath $ownershipPath
        $hasOwnership = (Test-Path -LiteralPath $ownershipPath -PathType Leaf) -and
            ([IO.File]::ReadAllText($ownershipPath) -ceq $ownershipId)
        if (-not $hasOwnership -and (Test-Path -LiteralPath $ownershipPath)) {
            throw '播放器安装目录已有其他文件。请检查本机播放器目录。'
        }
        foreach ($path in @($stableLauncher, $stablePaths, $stableSettings, $stableStop)) {
            Assert-MusicSafePath $path
            if ((Test-Path -LiteralPath $path) -and -not $hasOwnership) {
                throw '播放器安装目录已有其他文件。请检查本机播放器目录。'
            }
        }

        Assert-MusicSafePath $stateDir -Tree
        $recordPath = Join-Path $stateDir 'process.json'
        $owned = $false
        if ($previous -and (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $oldScript = Join-Path $previous 'helper/server.mjs'
            $owned = $record.created -and $record.executable -ieq (Join-Path $previous 'runtime/node/node.exe') -and (Test-MusicProcess $record $oldScript)
        }
        $fonts = Join-Path $connection.gameDir 'data/databundles/fonts.zip'
        $portBusy = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port -contains 17863
        if ($portBusy -and -not $owned) {
            throw '17863 端口已被占用。请先用原目录的「停止播放器」关闭旧后台，再重试。'
        }
        if ($previous -ine $directory -or -not $owned) {
            Write-Output '正在检查配套播放器运行环境…'
            Test-CompanionEnvironment $directory
        }

        if (-not $hasOwnership) { Write-MusicText $ownershipPath $ownershipId }
        foreach ($copy in @(
            @{Source=$PSCommandPath; Destination=$stableLauncher},
            @{Source=(Join-Path $PSScriptRoot 'Runtime-Paths.ps1'); Destination=$stablePaths},
            @{Source=(Join-Path $workshopPath '自启动设置.cmd'); Destination=$stableSettings},
            @{Source=(Join-Path $PSScriptRoot '停止配套播放器.cmd'); Destination=$stableStop}
        )) {
            Assert-MusicSafePath $copy.Source
            $content = [IO.File]::ReadAllText($copy.Source)
            $temporary = $copy.Destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($copy.Destination.EndsWith('.ps1')))
                if (Test-Path -LiteralPath $copy.Destination) { [IO.File]::Replace($temporary, $copy.Destination, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $copy.Destination) }
            } finally {
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
            }
        }
        Write-Output '正在连接模组并启动播放器…'
        $snapshot = @{}
        foreach ($path in @((Join-Path $stateDir 'install.json'), (Join-Path $stateDir 'bridge.json'),
            (Join-Path $connection.modDir 'scripts/dangomusic_connection.lua'))) {
            Assert-MusicSafePath $path
            if (Test-Path -LiteralPath $path -PathType Leaf) { $snapshot[$path] = [IO.File]::ReadAllText($path) }
            else { $snapshot[$path] = $null }
        }
        $stoppedOld = $false
        $startAttempted = $false
        try {
            if ($owned -and ($previous -ine $directory -or $record.runtimeModDir -ine $connection.modDir -or $record.fontsPath -ine $fonts)) {
                Write-Output '正在停止旧版配套播放器…'
                & (Join-Path $previous 'Stop-Player.ps1') -StateDir $stateDir -Wait
                $stoppedOld = $true
            }
            & (Join-Path $directory 'Connect-Workshop.ps1') -GamePath $connection.gameDir -ModPath $connection.modDir -StateDir $stateDir | Out-Null
            $startAttempted = $true
            & (Join-Path $directory 'Start-Player.ps1') -StateDir $stateDir -NoBrowser | Out-Null
            Write-MusicText $currentPath ($manifest | ConvertTo-Json)
        } catch {
            $reason = $_.Exception.Message
            try {
                if ($startAttempted -and (-not $owned -or $stoppedOld) -and (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
                    $failed = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($failed.created -and $failed.executable -ieq (Join-Path $directory 'runtime/node/node.exe') -and
                        (Test-MusicProcess $failed (Join-Path $directory 'helper/server.mjs'))) {
                        & (Join-Path $directory 'Stop-Player.ps1') -StateDir $stateDir -Wait | Out-Null
                    }
                }
            } catch { $reason += ' 自动停止此次启动的播放器失败。' }
            try {
                foreach ($path in $snapshot.Keys) {
                    Assert-MusicSafePath $path
                    if ($null -ne $snapshot[$path]) { Write-MusicText $path $snapshot[$path] }
                    elseif (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) }
                }
                if ($stoppedOld) {
                    & (Join-Path $previous 'Start-Player.ps1') -StateDir $stateDir -NoBrowser | Out-Null
                    $reason += ' 已恢复上次运行的播放器。'
                }
            } catch { $reason += ' 自动恢复失败。请检查播放器目录，或重新运行上次使用的版本。' }
            throw $reason
        }
        Write-Output '播放器已就绪。回到游戏，点 ESC → 设置 → 连接播放器。'
        Write-Output ('播放器安装目录：' + $installDir)
    } finally { $lock.Dispose() }
} catch {
    $message = $_.Exception.Message
    if ($message -match 'junction|符号链接') { $message = '模组或本机播放器路径包含目录链接。请使用实际 Steam 库路径和普通 Windows 用户数据目录。' }
    if (-not $AutoStart) { [Console]::Error.WriteLine($message) }
    exit 1
}
