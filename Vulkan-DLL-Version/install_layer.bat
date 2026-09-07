@echo off
echo ============================================
echo   RandOverlay - Install Vulkan Layer
echo ============================================
echo.

:: Get absolute path to JSON manifest
set "MANIFEST=%~dp0RandOverlay_layer.json"

:: Register as implicit layer (per-user, no admin needed)
reg add "HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers" /v "%MANIFEST%" /t REG_DWORD /d 0 /f >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to add registry entry.
    echo Try running as administrator.
) else (
    echo [OK] Layer registered: %MANIFEST%
    echo.
    echo The overlay will auto-load next time RPCS3 starts.
    echo To disable without uninstalling: set DISABLE_RANDOVERLAY=1
)
echo.
pause
