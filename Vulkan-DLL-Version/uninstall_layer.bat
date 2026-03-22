@echo off
echo ============================================
echo   RandOverlay - Uninstall Vulkan Layer
echo ============================================
echo.

set "MANIFEST=%~dp0RandOverlay_layer.json"

reg delete "HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers" /v "%MANIFEST%" /f >nul 2>&1
if errorlevel 1 (
    echo [INFO] Layer was not registered.
) else (
    echo [OK] Layer unregistered.
    echo RPCS3 will no longer load the overlay.
)
echo.
pause
