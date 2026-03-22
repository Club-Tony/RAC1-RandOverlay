@echo off
title RandOverlay
echo ============================================
echo   RandOverlay (PowerShell + WPF)
echo ============================================
echo.
echo  Toggle Overlay:  Ctrl+Alt+A
echo  Toggle Font:     Ctrl+Alt+F
echo.
echo Starting overlay...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0RandOverlay.ps1"
echo.
echo Overlay exited. Check RandOverlay.log if there were errors.
pause
