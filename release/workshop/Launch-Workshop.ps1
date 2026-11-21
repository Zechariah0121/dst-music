param([switch]$AutoStart, [switch]$Settings, [switch]$Stop)

$ErrorActionPreference = 'Stop'
$workshopId = '3836261433'
$runKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run'
$runName = 'ZccDSTMusic'
$ownershipId = 'zcc-dst-music-workshop-launcher-v1'
$stableNames = @('Launch-Workshop.ps1', 'Runtime-Paths.ps1', '自启动设置.cmd', '停止配套播放器.cmd')

function Resolve-WorkshopInstallPath([string]$Path, [string]$SourceModPath) {
    $pathText = $Path.Trim()
    if ($pathText -notmatch '^(?:[a-z]:[\\/]|\\\\[^.\\/?][^\\/]*\\[^\\/]+(?:[\\/]|$))') {
        throw '请输入完整的 Windows 文件夹路径。'
    }
    $directory = Get-MusicUniquePaths $pathText
    $root = [IO.Path]::GetPathRoot($directory)
    foreach ($part in $directory.Substring($root.Length).TrimStart('\').Split('\')) {
        if ($part -match '[:\x00-\x1f<>|?*"]|[. ]$|^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9¹²³]|LPT[0-9¹²³])(?:\.|$)') {
            throw '文件夹路径包含 Windows 不支持的名称。'
        }
    }
    if ($SourceModPath -and ($directory -ieq $SourceModPath -or $directory.StartsWith($SourceModPath + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw '请选择 Steam 模组文件夹以外的目录，以便更新模组时保留播放器和数据。'
    }
    Assert-MusicSafePath $directory
    if (Test-Path -LiteralPath $directory -PathType Leaf) { throw '此路径指向文件，请选择文件夹。' }
    return $directory
}

function Test-WorkshopInstallOwnership([string]$Directory) {
    $marker = Join-Path $Directory 'bootstrap.id'
    Assert-MusicSafePath $marker
    return (Test-Path -LiteralPath $marker -PathType Leaf) -and
        ([IO.FileInfo]::new($marker).Length -le 128) -and ([IO.File]::ReadAllText($marker) -ceq $ownershipId)
}

function Assert-WorkshopInstallAvailable([string]$Directory) {
    if (-not [IO.Directory]::Exists([IO.Path]::GetPathRoot($Directory))) { throw '所选磁盘或网络位置不可用，请接入磁盘或重新选择目录。' }
    if (Test-WorkshopInstallOwnership $Directory) { return }
    foreach ($name in ($stableNames + @('bootstrap.id', 'versions', '.state', 'current.json', 'launcher.lock'))) {
        $path = Join-Path $Directory $name
        Assert-MusicSafePath $path
        if (Test-Path -LiteralPath $path) { throw '此目录已包含同名文件或目录，请选择其他文件夹。' }
    }
}

function Show-WorkshopInstallDirectory([string]$DefaultDirectory, [string]$SourceModPath, [string]$PreviousDirectory, [string]$RecoveryReason) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = [Windows.Forms.Form]::new()
    try {
        $form.Text = '云间音乐 · 选择播放器安装目录'
        $form.ClientSize = [Drawing.Size]::new(660, 256)
        $form.FormBorderStyle = 'FixedDialog'
        $form.StartPosition = 'CenterScreen'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $hint = [Windows.Forms.Label]::new()
        $hint.Text = '选择配套播放器的解压位置。程序、账号设置和缓存都会保存在此目录。'
        $hint.SetBounds(20, 20, 620, 22)
        $location = [Windows.Forms.TextBox]::new()
        $location.Text = $DefaultDirectory
        if ($PreviousDirectory) { $location.Text = $PreviousDirectory }
        $location.SetBounds(22, 52, 518, 24)
        $browse = [Windows.Forms.Button]::new()
        $browse.Text = '浏览…'
        $browse.SetBounds(552, 49, 86, 28)
        $browse.Add_Click({
            $picker = [Windows.Forms.FolderBrowserDialog]::new()
            try {
                $picker.Description = '选择配套播放器的解压位置'
                $picker.ShowNewFolderButton = $true
                if ([IO.Directory]::Exists($location.Text)) { $picker.SelectedPath = $location.Text }
                if ($picker.ShowDialog($form) -eq 'OK') { $location.Text = $picker.SelectedPath }
            } finally { $picker.Dispose() }
        }.GetNewClosure())
        $restore = [Windows.Forms.Button]::new()
        $restore.Text = '使用默认目录'
        $restore.SetBounds(22, 199, 116, 32)
        $restore.Add_Click({ $location.Text = $DefaultDirectory }.GetNewClosure())
        $notice = [Windows.Forms.Label]::new()
        $notice.Text = '以后启动和更新时会继续使用所选目录。'
        if ($RecoveryReason) {
            $notice.Text = $RecoveryReason + "`r`n请恢复原目录或接入磁盘，也可以重新选择安装位置。原账号和缓存若仍保留，请选择其原目录；选择空目录会创建新数据，不会自动迁移旧数据。"
        }
        $notice.SetBounds(20, 90, 620, 96)
        $install = [Windows.Forms.Button]::new()
        $install.Text = '解压并启动'
        $install.DialogResult = 'OK'
        $install.SetBounds(438, 199, 106, 32)
        $cancel = [Windows.Forms.Button]::new()
        $cancel.Text = '取消'
        $cancel.DialogResult = 'Cancel'
        $cancel.SetBounds(552, 199, 86, 32)
        $form.Controls.AddRange(@($hint, $location, $browse, $restore, $notice, $install, $cancel))
        $form.AcceptButton = $install
        $form.CancelButton = $cancel
        $form.ActiveControl = $location
        while ($form.ShowDialog() -eq 'OK') {
            try {
                $directory = Resolve-WorkshopInstallPath $location.Text $SourceModPath
                Assert-WorkshopInstallAvailable $directory
                Assert-WorkshopInstallWritable $directory
                return $directory
            } catch {
                $notice.Text = $_.Exception.Message
                $notice.ForeColor = [Drawing.Color]::Firebrick
                $form.DialogResult = 'None'
            }
        }
    } finally { $form.Dispose() }
}

function Assert-WorkshopInstallWritable([string]$Directory) {
    # 只在确认磁盘可用后创建目录，避免离线磁盘被误当成新安装位置。
    $root = [IO.Path]::GetPathRoot($Directory)
    if (-not [IO.Directory]::Exists($root)) { throw '所选磁盘或网络位置不可用，请接入磁盘或重新选择目录。' }
    Assert-MusicSafePath $Directory
    $probe = Join-Path $Directory ('.write-check-' + [guid]::NewGuid().ToString('N') + '.tmp')
    Assert-MusicSafePath $probe
    try {
        [IO.Directory]::CreateDirectory($Directory) | Out-Null
        $file = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $file.Dispose()
    } catch {
        throw ('播放器目录无法写入，请检查权限或重新选择目录：' + $Directory)
    } finally {
        if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) }
    }
}

function Write-NewWorkshopText([string]$Path, [string]$Text) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $file = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
            $file.Write($bytes, 0, $bytes.Length)
        } finally { $file.Dispose() }
        [IO.File]::Move($temporary, $Path)
    } finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
    }
}

function Get-WorkshopInstallDirectory([string]$DefaultDirectory, [string]$SourceModPath, [switch]$ChooseDirectory) {
    # 工坊各副本共用选择锁，不在默认目录留下首次安装锁文件。
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($DefaultDirectory.ToUpperInvariant()))).Replace('-', '') }
    finally { $hash.Dispose() }
    $mutex = [Threading.Mutex]::new($false, ('Global\ZccDSTMusic-' + $key))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '播放器启动器正在选择安装目录，请在当前窗口完成后再试。' }

        $locationPath = Join-Path $DefaultDirectory 'install-location.json'
        Assert-MusicSafePath $locationPath
        $previousDirectory = $null
        $pendingPreviousDirectory = $null
        $recoveryReason = $null
        if (Test-Path -LiteralPath $locationPath) {
            try {
                if ([IO.FileInfo]::new($locationPath).Length -gt 16384) { throw 'Invalid record size' }
                $record = Get-Content -LiteralPath $locationPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($record -isnot [pscustomobject] -or $record.schema -isnot [int] -or $record.schema -ne 1 -or $record.path -isnot [string]) {
                    throw 'Invalid record structure'
                }
                $directory = Resolve-WorkshopInstallPath $record.path $SourceModPath
                if ($record.PSObject.Properties['previousPath']) {
                    if ($record.previousPath -isnot [string]) { throw 'Invalid previous path' }
                    $pendingPreviousDirectory = Resolve-WorkshopInstallPath $record.previousPath $SourceModPath
                }
            } catch {
                throw ('无法读取播放器安装位置记录。请检查此文件：' + $locationPath)
            }
            if ((Test-Path -LiteralPath $directory -PathType Container) -and (Test-WorkshopInstallOwnership $directory)) {
                $script:workshopPreviousInstallDirectory = $pendingPreviousDirectory
                if (-not $ChooseDirectory) { return $directory }
                try { Assert-WorkshopInstallWritable $directory; return $directory }
                catch { $recoveryReason = $_.Exception.Message }
            } else {
                $recoveryReason = '上次选择的播放器目录已不可用。'
            }
            if (-not $ChooseDirectory) { throw ($recoveryReason + '请从工坊运行「一键启动播放器」重新选择，或恢复原目录、重新接入磁盘：' + $directory) }
            $previousDirectory = $directory
        }

        if (-not $previousDirectory -and (Test-WorkshopInstallOwnership $DefaultDirectory)) {
            if (-not $ChooseDirectory) { return $DefaultDirectory }
            try { Assert-WorkshopInstallWritable $DefaultDirectory; return $DefaultDirectory }
            catch { $previousDirectory = $DefaultDirectory; $recoveryReason = $_.Exception.Message }
        }
        if (-not $ChooseDirectory) { throw '请先双击工坊目录里的「一键启动播放器」。' }
        $directory = Show-WorkshopInstallDirectory $DefaultDirectory $SourceModPath $previousDirectory $recoveryReason
        if (-not $directory) { return }
        $directory = Resolve-WorkshopInstallPath $directory $SourceModPath
        Assert-WorkshopInstallAvailable $directory
        Assert-MusicSafePath (Join-Path $directory '.state') -Tree
        Assert-WorkshopInstallWritable $directory
        $marker = Join-Path $directory 'bootstrap.id'
        Assert-MusicSafePath $marker
        if (-not (Test-WorkshopInstallOwnership $directory)) { Write-NewWorkshopText $marker $ownershipId }
        [IO.Directory]::CreateDirectory($DefaultDirectory) | Out-Null
        Assert-MusicSafePath $locationPath
        # 只有用户确认且目标可写后才替换旧指针；取消和验证失败保留原记录。
        $nextRecord = @{schema=1; path=$directory}
        $previousStartupDirectory = $previousDirectory
        if ($pendingPreviousDirectory) { $previousStartupDirectory = $pendingPreviousDirectory }
        if ($previousStartupDirectory -and $previousStartupDirectory -ine $directory) { $nextRecord.previousPath = $previousStartupDirectory }
        Write-MusicText $locationPath ($nextRecord | ConvertTo-Json -Compress)
        $script:workshopPreviousInstallDirectory = $nextRecord.previousPath
        return $directory
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

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

function Get-AutoStartCommand([string]$Directory = $installDir) {
    $powershell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    return ('"' + $powershell + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + [IO.Path]::Combine($Directory, 'Launch-Workshop.ps1') + '" -AutoStart')
}

function Update-WorkshopRecoveredAutoStart([string]$PreviousDirectory) {
    if (-not $PreviousDirectory -or $PreviousDirectory -ieq $installDir) { return }
    $existing = Get-AutoStartEntry
    # 只跟随确切属于原安装位置的已启用项，不接管其他程序或异常类型。
    if (-not $existing -or $existing.kind -ne [Microsoft.Win32.RegistryValueKind]::String -or
        $existing.value -cne (Get-AutoStartCommand $PreviousDirectory)) { return }
    $command = Get-AutoStartCommand
    if ($command.Length -gt 260) { throw '新目录过长，无法更新随 Windows 启动的位置。请重新选择较短目录后设置自启动。' }
    Assert-MusicSafePath (Join-Path $installDir 'Launch-Workshop.ps1')
    Assert-MusicSafePath $currentPath
    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'Launch-Workshop.ps1') -PathType Leaf) -or
        -not (Get-InstalledCompanion (Read-CompanionManifest $currentPath) -CheckFiles)) {
        throw '新目录尚未完成安装，保留原自启动项。'
    }
    Set-ItemProperty -LiteralPath $runKey -Name $runName -Value $command
}

function Complete-WorkshopInstallRecovery([string]$DefaultDirectory) {
    if (-not $script:workshopPreviousInstallDirectory) { return }
    $locationPath = Join-Path $DefaultDirectory 'install-location.json'
    Assert-MusicSafePath $locationPath
    $record = Get-Content -LiteralPath $locationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.path -ine $installDir) { throw '安装位置记录已改变，请重新运行工坊启动器。' }
    # 新位置启动成功且自启动已处理后才移除待恢复字段，失败重试仍记得原启动项。
    $record.PSObject.Properties.Remove('previousPath')
    Write-MusicText $locationPath ($record | ConvertTo-Json -Compress)
    $script:workshopPreviousInstallDirectory = $null
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
    $script:workshopPreviousInstallDirectory = $null
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localData) { throw 'Windows 无法找到本机应用数据目录。' }
    $defaultDir = [IO.Path]::GetFullPath((Join-Path $localData ('Zcc/DST-Music/Workshop/' + $workshopId)))
    . (Join-Path $PSScriptRoot 'Runtime-Paths.ps1')
    $launchFromWorkshop = -not ($AutoStart -or $Stop -or $Settings)
    $workshopPath = $null
    if ($launchFromWorkshop) {
        $workshopPath = Split-Path $PSScriptRoot -Parent
        $modName = Split-Path $workshopPath -Leaf
        if ($modName -cnotin @($workshopId, ('workshop-' + $workshopId))) {
            throw '请在 Steam 下载的本模组目录里双击「一键启动播放器」。'
        }
        $connection = Find-MusicWorkshopConnection -ModPath $workshopPath
        $manifest = Read-CompanionManifest (Join-Path $PSScriptRoot 'companion.json')
        $null = Get-CompanionPackage $manifest
    }
    $installDir = Get-WorkshopInstallDirectory $defaultDir $workshopPath -ChooseDirectory:$launchFromWorkshop
    if (-not $installDir) { Write-Output '已取消播放器安装。'; return }
    if ($AutoStart -and $PSScriptRoot -ine $installDir) { throw '请从已安装的播放器目录运行此选项。' }
    $versionsDir = Join-Path $installDir 'versions'
    $stateDir = Join-Path $installDir '.state'
    $currentPath = Join-Path $installDir 'current.json'
    Assert-MusicSafePath $versionsDir
    Assert-MusicSafePath $stateDir

    $lockPath = Join-Path $installDir 'launcher.lock'
    Assert-MusicSafePath $lockPath
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw '播放器启动器正在运行，请等当前操作完成后再试。' }
    try {
        if ($Settings) { Show-AutoStartSettings; return }
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

        $stableLauncher = Join-Path $installDir 'Launch-Workshop.ps1'
        $stablePaths = Join-Path $installDir 'Runtime-Paths.ps1'
        $stableSettings = Join-Path $installDir '自启动设置.cmd'
        $stableStop = Join-Path $installDir '停止配套播放器.cmd'
        foreach ($path in @($stableLauncher, $stablePaths, $stableSettings, $stableStop)) { Assert-MusicSafePath $path }
        Assert-MusicSafePath $stateDir -Tree
        [IO.Directory]::CreateDirectory($versionsDir) | Out-Null
        $directory = Get-InstalledCompanion $manifest -CheckFiles
        if (-not $directory) {
            $directory = Install-Companion $manifest (Join-Path $PSScriptRoot ($manifest.package + '.zip'))
        }

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
        try {
            Update-WorkshopRecoveredAutoStart $script:workshopPreviousInstallDirectory
            Complete-WorkshopInstallRecovery $defaultDir
        }
        catch { Write-Output ('播放器已启动，但安装位置或自启动恢复尚未完成：' + $_.Exception.Message) }
        Write-Output '播放器已就绪。回到游戏，点 ESC → 音乐播放器 → 连接播放器。'
        Write-Output ('播放器安装目录：' + $installDir)
    } finally { $lock.Dispose() }
} catch {
    $message = $_.Exception.Message
    if ($message -match 'junction|符号链接') { $message = '模组或本机播放器路径包含目录链接。请使用实际 Steam 库路径和普通文件夹。' }
    if (-not $AutoStart) { [Console]::Error.WriteLine($message) }
    exit 1
}
