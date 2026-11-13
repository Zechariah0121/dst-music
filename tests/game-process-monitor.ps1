# Real, isolated Windows process lifetime checks. Never stops a game process.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'helper/GameProcessMonitor.cs')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('music-process-monitor-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$clientName = 'music_client_' + [guid]::NewGuid().ToString('N')
$serverName = 'music_server_' + [guid]::NewGuid().ToString('N')
$clientExe = Join-Path $fixture ($clientName + '.exe')
$serverExe = Join-Path $fixture ($serverName + '.exe')
Add-Type -TypeDefinition 'public static class GameProbeFixture { public static void Main() { System.Console.ReadLine(); } }' -OutputAssembly $clientExe -OutputType ConsoleApplication
Copy-Item -LiteralPath $clientExe -Destination $serverExe
$owned = @()
function Launch([string]$Path) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $process = [Diagnostics.Process]::Start($info)
    $script:owned += $process
    return $process
}
function Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Stop-Fixture($Process) {
    $Process.StandardInput.Close()
    Check ($Process.WaitForExit(3000)) 'Owned fixture did not exit'
}
try {
    $server = Launch $serverExe
    Check ([DangoMusic.GameProcessMonitor]::ReadPresence(@($clientName)) -eq $false) 'An unrelated server must not count as the client'
    $first = Launch $clientExe
    Check ([DangoMusic.GameProcessMonitor]::ReadPresence(@($clientName)) -eq $true) 'Client launch was not detected'
    $second = Launch $clientExe
    Stop-Fixture $first
    Check ([DangoMusic.GameProcessMonitor]::ReadPresence(@($clientName)) -eq $true) 'One remaining client should keep the session alive'
    Stop-Fixture $second
    Check ([DangoMusic.GameProcessMonitor]::ReadPresence(@($clientName)) -eq $false) 'Last client exit was not detected'
    Check (-not $server.HasExited) 'Server fixture should remain running after clients exit'
    $again = Launch $clientExe
    Check ([DangoMusic.GameProcessMonitor]::ReadPresence(@($clientName)) -eq $true) 'Reopened client was not detected'
    Stop-Fixture $again
    Check ([DangoMusic.GameProcessMonitor]::ReadPresence(@($clientName)) -eq $false) 'Second exit was not detected'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($i=0;$i -lt 20;$i++) { $null = [DangoMusic.GameProcessMonitor]::IsClientRunning() }
    $watch.Stop()
    Write-Output ('PASS isolated client launch/exit, remaining client, unrelated server and reopening. Mean OS probe: ' + [Math]::Round($watch.Elapsed.TotalMilliseconds/20,2) + ' ms')
} finally {
    foreach ($process in $owned) {
        try { if (-not $process.HasExited) { $process.StandardInput.Close(); if (-not $process.WaitForExit(3000)) { $process.Kill(); $process.WaitForExit() } } }
        finally { $process.Dispose() }
    }
}
