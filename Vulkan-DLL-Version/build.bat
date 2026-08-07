@echo off
title RandOverlay Vulkan Build
echo ============================================
echo   Building RandOverlay Vulkan Overlay
echo ============================================
echo.

set VKSDK=C:\VulkanSDK\1.4.341.1
set MINHOOK=deps\minhook
set IMGUI=deps\imgui

:: Prefer a known x64 MinGW-w64 toolchain; fall back to PATH.
set GCC=g++
set GCC_C=gcc
set AR=ar
if exist C:\mingw64\bin\g++.exe set GCC=C:\mingw64\bin\g++
if exist C:\mingw64\bin\gcc.exe set GCC_C=C:\mingw64\bin\gcc
:: ar must come from the SAME x64 toolchain: a bare 'ar' can resolve to the
:: 32-bit MinGW.org binutils, whose archive the x86_64 ld cannot index
:: ("archive has no index"), breaking the fallback link.
if exist C:\mingw64\bin\ar.exe set AR=C:\mingw64\bin\ar

:: --- Arch guard: a 32-bit DLL cannot load into RPCS3/PCSX2 (both x64) --------
set GMACHINE=
for /f "delims=" %%m in ('"%GCC%" -dumpmachine 2^>nul') do set GMACHINE=%%m
echo Toolchain: %GCC%  (%GMACHINE%)
echo %GMACHINE% | findstr /i "x86_64" >nul
if errorlevel 1 (
    echo.
    echo   [ERROR] '%GCC%' targets '%GMACHINE%', not x86_64.
    echo   A 32-bit DLL will NOT load into RPCS3/PCSX2. Install/point to an
    echo   x86_64-w64-mingw32 g++ ^(e.g. C:\mingw64\bin^) and re-run.
    goto fail
)
echo.

if not exist build mkdir build

:: === [1/4] RandOverlay implicit layer (PRIMARY) ==============================
echo [1/4] Building RandOverlay_layer.dll (implicit layer + ImGui)...
"%GCC%" -shared -O2 -std=c++17 ^
    -DWIN32_LEAN_AND_MEAN -DVK_NO_PROTOTYPES -DIMGUI_IMPL_VULKAN_NO_PROTOTYPES ^
    -I "%VKSDK%\Include" -I %IMGUI% -I %IMGUI%\backends -I src ^
    src\layer.cpp ^
    %IMGUI%\imgui.cpp %IMGUI%\imgui_draw.cpp %IMGUI%\imgui_tables.cpp %IMGUI%\imgui_widgets.cpp ^
    %IMGUI%\backends\imgui_impl_vulkan.cpp ^
    -o build\RandOverlay_layer.dll ^
    -lkernel32 -luser32 -lshell32 -ladvapi32 ^
    -static -static-libgcc -static-libstdc++ ^
    -Wl,--kill-at
if errorlevel 1 goto fail
echo   RandOverlay_layer.dll OK
echo.

:: === [2/4] MinHook (for the injected-DLL fallback) ==========================
echo [2/4] Building MinHook...
"%GCC_C%" -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\buffer.c     -o build\buffer.o
"%GCC_C%" -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\hook.c       -o build\hook.o
"%GCC_C%" -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\trampoline.c -o build\trampoline.o
"%GCC_C%" -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\hde\hde64.c  -o build\hde64.o
"%AR%" rcs build\libminhook.a build\buffer.o build\hook.o build\trampoline.o build\hde64.o
if errorlevel 1 goto fail
echo   MinHook OK
echo.

:: === [3/4] overlay.dll (injected-DLL FALLBACK) ==============================
echo [3/4] Building overlay.dll (fallback)...
"%GCC%" -shared -O2 -std=c++17 -DWIN32_LEAN_AND_MEAN ^
    -I "%VKSDK%\Include" -I %MINHOOK%\include -I src ^
    src\overlay.cpp ^
    -o build\overlay.dll ^
    -L build -lminhook ^
    -L "%VKSDK%\Lib" -lvulkan-1 ^
    -lkernel32 -luser32 -lpsapi ^
    -static -static-libgcc -static-libstdc++ ^
    -Wl,--kill-at
if errorlevel 1 goto fail
echo   overlay.dll OK
echo.

:: === [4/4] injector.exe (loads overlay.dll into a running emulator) =========
echo [4/4] Building injector.exe (fallback)...
"%GCC%" -O2 -std=c++17 -DWIN32_LEAN_AND_MEAN ^
    src\injector.cpp ^
    -o build\injector.exe ^
    -lkernel32 -luser32 -lpsapi ^
    -static -static-libgcc -static-libstdc++
if errorlevel 1 goto fail
echo   injector.exe OK

echo.
echo ============================================
echo   Build complete!
echo   PRIMARY:  build\RandOverlay_layer.dll  (install_layer.bat)
echo   FALLBACK: build\injector.exe + build\overlay.dll
echo ============================================
goto end

:fail
echo.
echo   BUILD FAILED - check errors above
:end
pause
