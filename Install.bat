@echo off
rem ------------------------------------------------------------------
rem  Installs Video Compressor on this computer (no admin rights needed).
rem  Double-click this file. It copies the app to a folder you can write
rem  to, checks it runs there, and adds a Desktop icon and a right-click
rem  "Send to" entry. Safe to run again to update; settings are kept.
rem ------------------------------------------------------------------
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Install.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
