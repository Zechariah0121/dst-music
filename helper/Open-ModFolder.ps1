$ErrorActionPreference = 'Stop'

function Find-FolderWindow($Shell, [string]$Directory) {
    foreach ($window in $Shell.Windows()) {
        try {
            if ([IO.Path]::GetFileName([string]$window.FullName) -ine 'explorer.exe') { continue }
            $url = [uri]$window.LocationURL
            if ($url.IsAbsoluteUri -and $url.IsFile -and
                [IO.Path]::GetFullPath($url.LocalPath).TrimEnd('\') -ieq $Directory) {
                return [IntPtr][long]$window.HWND
            }
        } catch {
            # ShellWindows may include a window whose tab is closing.
        }
    }
    return [IntPtr]::Zero
}

try {
    if (-not $env:DST_MUSIC_MOD_FOLDER) { exit 1 }
    $directory = [IO.Path]::GetFullPath($env:DST_MUSIC_MOD_FOLDER).TrimEnd('\')
    if (-not [IO.Directory]::Exists($directory)) { exit 1 }

    $shell = New-Object -ComObject Shell.Application
    $window = Find-FolderWindow $shell $directory
    if ($window -eq [IntPtr]::Zero) {
        $shell.Explore($directory)
        for ($attempt = 0; $attempt -lt 15 -and $window -eq [IntPtr]::Zero; $attempt++) {
            Start-Sleep -Milliseconds 100
            $window = Find-FolderWindow $shell $directory
        }
    }
    if ($window -ne [IntPtr]::Zero) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MusicFolderWindow {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
}
'@
            if ([MusicFolderWindow]::IsIconic($window)) {
                $null = [MusicFolderWindow]::ShowWindowAsync($window, 9)
            }
            if ([MusicFolderWindow]::GetForegroundWindow() -ne $window) {
                $null = [MusicFolderWindow]::SetForegroundWindow($window)
                Start-Sleep -Milliseconds 120
            }
            if ([MusicFolderWindow]::GetForegroundWindow() -eq $window) { exit 0 }
        } catch {
            # Opening the folder succeeded even if foreground activation is unavailable.
        }
        exit 10
    }
    exit 11
} catch {
    exit 1
}
