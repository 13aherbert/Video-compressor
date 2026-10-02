@echo off
rem ------------------------------------------------------------------
rem  Portable video compressor launcher
rem  Double-click to open the window, or drop video files / folders
rem  onto this file to pre-load them. Nothing is installed.
rem ------------------------------------------------------------------
setlocal
set "ROOT=%~dp0"

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo PowerShell was not found on this computer. It ships with Windows 10 and 11,
    echo so this is unusual. Try running  src\Main.ps1  from a PowerShell window.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%ROOT%src\Main.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Something went wrong ^(exit code %RC%^). The newest file in the "logs" folder has details.
    pause
)
endlocal & exit /b %RC%
