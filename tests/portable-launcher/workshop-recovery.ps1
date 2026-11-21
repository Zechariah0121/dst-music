param([string]$LauncherSourcePath, [switch]$ExpectBlocked)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $LauncherSourcePath) { $LauncherSourcePath = Join-Path $root 'release/workshop/Launch-Workshop.ps1' }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dst-r-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$default = Join-Path $fixture 'default'
$recordPath = Join-Path $default 'install-location.json'
$original = Join-Path $fixture 'deleted player'
$ownershipId = 'zcc-dst-music-workshop-launcher-v1'
$stableNames = @('Launch-Workshop.ps1', 'Runtime-Paths.ps1', '自启动设置.cmd', '停止配套播放器.cmd')
$script:pickerCount = 0
$script:choice = $null
$script:pickerPrevious = $null
$script:pickerReason = $null
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Fixture([string]$Path, [string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true))
}
function Save-Location([string]$Directory) { Write-Fixture $recordPath (@{schema=1;path=$Directory} | ConvertTo-Json -Compress) }
function New-Owned([string]$Directory) { Write-Fixture (Join-Path $Directory 'bootstrap.id') $ownershipId }
function Expect-Failure([scriptblock]$Action, [string]$Text) {
    $failed = $false
    $actual = '未报错'
    try { & $Action | Out-Null } catch { $actual = $_.Exception.Message; $failed = $actual.Contains($Text) }
    Assert $failed ('应失败并包含：' + $Text + '；实际：' + $actual)
}
. (Join-Path $root 'Runtime-Paths.ps1')
$tokens = $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($LauncherSourcePath, [ref]$tokens, [ref]$errors)
Assert (-not $errors) '启动器语法解析失败'
foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Show-WorkshopInstallDirectory([string]$DefaultDirectory, [string]$SourceModPath, [string]$PreviousDirectory, [string]$RecoveryReason) {
    $script:pickerCount++
    $script:pickerPrevious = $PreviousDirectory
    $script:pickerReason = $RecoveryReason
    Assert ($DefaultDirectory -ceq $default) '恢复时丢失默认目录'
    return $script:choice
}

Save-Location $original
$before = [IO.File]::ReadAllText($recordPath)
if ($ExpectBlocked) {
    $script:choice = $original
    Expect-Failure { Get-WorkshopInstallDirectory $default '' -ChooseDirectory } '上次选择的播放器目录已不可用'
    Assert ($script:pickerCount -eq 0 -and [IO.File]::ReadAllText($recordPath) -ceq $before) '旧版缺陷未重现'
    Write-Output ('PASS 旧版重现：目录被删除后，即使允许选择也直接报错；选择窗口调用 0 次。Fixture: ' + $fixture)
    exit 0
}

# 取消和非交互入口保留旧记录，不创建旧目录，也不触碰自启动。
$runKey = 'Fixture:/Run'
$runName = 'ZccDSTMusic'
$script:registryWrites = 0
function Set-ItemProperty { throw '恢复选择期间不得写入自启动项' }
$null = Get-WorkshopInstallDirectory $default '' -ChooseDirectory
Assert ($script:pickerCount -eq 1 -and $script:pickerPrevious -ceq $original -and $script:pickerReason.Contains('不可用')) '缺目录没有进入显式恢复流程'
Assert ([IO.File]::ReadAllText($recordPath) -ceq $before -and -not [IO.Directory]::Exists($original)) '取消改变旧指针或重建目录'
Expect-Failure { Get-WorkshopInstallDirectory $default '' } '重新选择'
Assert ($script:pickerCount -eq 1) '非交互入口打开选择窗口'

# 明确确认原路径后才重建；后续启动复用账号和缓存，不再弹窗。
$script:choice = $original
$selected = Get-WorkshopInstallDirectory $default '' -ChooseDirectory
Assert ($selected -ceq $original -and (Test-WorkshopInstallOwnership $original)) '不能在原位置重建已删除的安装'
$account = Join-Path $original '.state/account.json'
Write-Fixture $account 'original account and cache'
$count = $script:pickerCount
$script:choice = $null
Assert ((Get-WorkshopInstallDirectory $default '' -ChooseDirectory) -ceq $original -and $script:pickerCount -eq $count -and
    [IO.File]::ReadAllText($account) -ceq 'original account and cache') '现存账号目录没有被复用'

# 磁盘离线时可取消或改选，不自动在默认目录生成新账号。
$drive = @('Z','Y','X','W','V') | Where-Object { -not [IO.Directory]::Exists($_ + ':\') } | Select-Object -First 1
Assert $drive '找不到用于离线磁盘测试的未挂载盘符'
$offline = $drive + ':\missing-player'
Save-Location $offline
$before = [IO.File]::ReadAllText($recordPath)
$null = Get-WorkshopInstallDirectory $default '' -ChooseDirectory
Assert ($script:pickerPrevious -ceq $offline -and [IO.File]::ReadAllText($recordPath) -ceq $before) '离线磁盘取消更改记录'
$script:choice = $offline
Expect-Failure { Get-WorkshopInstallDirectory $default '' -ChooseDirectory } '不可用'
Assert ([IO.File]::ReadAllText($recordPath) -ceq $before -and -not (Test-Path -LiteralPath (Join-Path $default 'bootstrap.id'))) '离线磁盘被静默重建或迁到默认目录'
$replacement = Join-Path $fixture 'replacement'
New-Owned $replacement
$replacementAccount = Join-Path $replacement '.state/account.json'
Write-Fixture $replacementAccount 'existing chosen account'
$script:choice = $replacement
Assert ((Get-WorkshopInstallDirectory $default '' -ChooseDirectory) -ceq $replacement -and
    ([IO.File]::ReadAllText($recordPath) | ConvertFrom-Json).path -ceq $replacement -and
    [IO.File]::ReadAllText($replacementAccount) -ceq 'existing chosen account') '改选现存安装没有保留其账号'
Assert ($script:workshopPreviousInstallDirectory -ceq $offline) '改选丢失旧自启动项的匹配位置'

# 通过仅作用于夹具目录的 ACL 验证真实拒写，最后恢复原 ACL。
Save-Location $original
$acl = Get-Acl -LiteralPath $original
$deniedAcl = Get-Acl -LiteralPath $original
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
$rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::CreateFiles, [Security.AccessControl.AccessControlType]::Deny)
$deniedAcl.AddAccessRule($rule)
try {
    Set-Acl -LiteralPath $original -AclObject $deniedAcl
    Expect-Failure { Assert-WorkshopInstallWritable $original } '无法写入'
    $before = [IO.File]::ReadAllText($recordPath)
    $script:choice = $null
    $null = Get-WorkshopInstallDirectory $default '' -ChooseDirectory
    Assert ($script:pickerReason.Contains('无法写入') -and [IO.File]::ReadAllText($recordPath) -ceq $before) '不可写目录没有允许取消恢复'
    $script:choice = $original
    Expect-Failure { Get-WorkshopInstallDirectory $default '' -ChooseDirectory } '无法写入'
    Assert ([IO.File]::ReadAllText($recordPath) -ceq $before) '不可写目标改变了旧记录'
    $script:choice = $replacement
    Assert ((Get-WorkshopInstallDirectory $default '' -ChooseDirectory) -ceq $replacement) '不可写旧目录不能改选'
} finally { Set-Acl -LiteralPath $original -AclObject $acl }

# 文件占用导致原子替换失败时仍能完整读取原指针。
Save-Location $offline
$before = [IO.File]::ReadAllText($recordPath)
$locked = [IO.File]::Open($recordPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $script:choice = $replacement
    Expect-Failure { Get-WorkshopInstallDirectory $default '' -ChooseDirectory } 'Replace'
    Assert ([IO.File]::ReadAllText($recordPath) -ceq $before) '替换失败破坏原指针'
} finally { $locked.Dispose() }

# 未拥有的同名数据、目录链接和状态目录链接都不能被恢复流程接管。
$foreign = Join-Path $fixture 'foreign'
Write-Fixture (Join-Path $foreign '.state/account.json') 'foreign account'
Save-Location $foreign
$foreignRecord = [IO.File]::ReadAllText($recordPath)
$script:choice = $null
$null = Get-WorkshopInstallDirectory $default '' -ChooseDirectory
Assert ($script:pickerPrevious -ceq $foreign -and [IO.File]::ReadAllText($recordPath) -ceq $foreignRecord) '所有权标记缺失时没有提供可取消的恢复'
$script:choice = $foreign
Expect-Failure { Get-WorkshopInstallDirectory $default '' -ChooseDirectory } '同名文件或目录'
Save-Location $offline
$before = [IO.File]::ReadAllText($recordPath)
$linked = Join-Path $fixture 'linked'
New-Item -ItemType Junction -Path $linked -Target $replacement | Out-Null
try {
    $script:choice = $linked
    Expect-Failure { Get-WorkshopInstallDirectory $default '' -ChooseDirectory } 'junction'
} finally { [IO.Directory]::Delete($linked) }
$stateLinked = Join-Path $fixture 'state-linked'
New-Owned $stateLinked
New-Item -ItemType Junction -Path (Join-Path $stateLinked '.state') -Target (Join-Path $replacement '.state') | Out-Null
try {
    $script:choice = $stateLinked
    Expect-Failure { Get-WorkshopInstallDirectory $default '' -ChooseDirectory } 'junction'
} finally { [IO.Directory]::Delete((Join-Path $stateLinked '.state')) }
Assert ([IO.File]::ReadAllText($recordPath) -ceq $before -and [IO.File]::ReadAllText($replacementAccount) -ceq 'existing chosen account') '拒绝不安全目标后仍改变指针或外部数据'

# 没有位置记录的旧版默认安装同样支持不可写恢复，取消不生成新记录。
[IO.File]::Delete($recordPath)
New-Owned $default
$legacyAcl = Get-Acl -LiteralPath $default
$legacyDeniedAcl = Get-Acl -LiteralPath $default
$legacyDeniedAcl.AddAccessRule($rule)
try {
    Set-Acl -LiteralPath $default -AclObject $legacyDeniedAcl
    $script:choice = $null
    $null = Get-WorkshopInstallDirectory $default '' -ChooseDirectory
    Assert ($script:pickerPrevious -ceq $default -and $script:pickerReason.Contains('无法写入') -and -not [IO.File]::Exists($recordPath)) '旧版默认目录无法写入时不能取消恢复'
} finally { Set-Acl -LiteralPath $default -AclObject $legacyAcl }

# 自启动只在新安装完整时更新确切旧项，失败、禁用和外来项均保持原样。
$installDir = $replacement
$currentPath = Join-Path $replacement 'current.json'
$script:runEntry = $null
function Get-AutoStartEntry { return $script:runEntry }
function Set-ItemProperty {
    param($LiteralPath, $Name, $Value)
    Assert ($LiteralPath -ceq $runKey -and $Name -ceq $runName) '意外注册表写入'
    $script:registryWrites++
    $script:runEntry = @{kind=[Microsoft.Win32.RegistryValueKind]::String;value=$Value}
}
function Get-InstalledCompanion { if ($script:fixtureComplete) { return $replacement } }
Write-Fixture (Join-Path $replacement 'Launch-Workshop.ps1') 'fixture launcher'
Write-Fixture $currentPath '{"schema":1}'
$oldCommand = Get-AutoStartCommand $offline
$newCommand = Get-AutoStartCommand
$script:runEntry = @{kind=[Microsoft.Win32.RegistryValueKind]::String;value=$oldCommand}
$script:fixtureComplete = $false
Expect-Failure { Update-WorkshopRecoveredAutoStart $offline } '尚未完成安装'
Assert ($script:runEntry.value -ceq $oldCommand -and $script:registryWrites -eq 0) '失败的安装更新自启动项'
$script:fixtureComplete = $true
Update-WorkshopRecoveredAutoStart $offline
Assert ($script:runEntry.value -ceq $newCommand -and $script:registryWrites -eq 1) '成功恢复没有跟随原已启用自启动偏好'
foreach ($entry in @($null,
    @{kind=[Microsoft.Win32.RegistryValueKind]::String;value='another app'},
    @{kind=[Microsoft.Win32.RegistryValueKind]::ExpandString;value=$oldCommand})) {
    $script:runEntry = $entry
    Update-WorkshopRecoveredAutoStart $offline
    Assert ($script:runEntry -eq $entry -and $script:registryWrites -eq 1) '恢复接管了禁用或外来自启动项'
}
Assert (-not (Get-ChildItem -LiteralPath $fixture -Recurse -Force -Filter '*.tmp')) '恢复测试留下写入临时文件'
Write-Output ('PASS 删除后重建、离线磁盘、取消、改选现存账号、真实 ACL 拒写、原子替换失败保留记录、冲突/链接拒绝、自启动内存替身。Fixture: ' + $fixture)
