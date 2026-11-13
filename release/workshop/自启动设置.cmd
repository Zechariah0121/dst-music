@echo off
setlocal DisableDelayedExpansion
set "launcher=%~dp0Launch-Workshop.ps1"
if not exist "%launcher%" set "launcher=%~dp0windows-player\Launch-Workshop.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%launcher%" -Settings
if errorlevel 1 pause
