@echo off
setlocal
title RAC RandOverlay Setup
cd /d "%~dp0"

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo RandOverlay setup requires Windows PowerShell, but powershell.exe was not found.
    echo Install or enable Windows PowerShell, then run this installer again.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-RandOverlay.ps1" %*
set "setupExit=%ERRORLEVEL%"

if not "%~1"=="" exit /b %setupExit%

echo.
if not "%setupExit%"=="0" echo Setup ended with error code %setupExit%.
pause
exit /b %setupExit%
