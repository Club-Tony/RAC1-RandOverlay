@echo off
title RandOverlay Vulkan Build
set NO_PAUSE=0
set BUILD_MODE=-O2
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-pause" set NO_PAUSE=1
if /i "%~1"=="--debug" set BUILD_MODE=-O0 -g -fno-omit-frame-pointer
shift
goto parse_args
:args_done
echo ============================================
echo   Building RandOverlay Vulkan Overlay
echo ============================================
echo.

set VKSDK=C:\VulkanSDK\1.4.341.1
if not "%VULKAN_SDK%"=="" set VKSDK=%VULKAN_SDK%
set MINHOOK=deps\minhook
set IMGUI=deps\imgui

:: Prefer a known x64 MinGW-w64 toolchain; fall back to PATH.
set GCC=g++
set GCC_C=gcc
set AR=ar
set WINDRES=windres
if exist C:\mingw64\bin\g++.exe set GCC=C:\mingw64\bin\g++
if exist C:\mingw64\bin\gcc.exe set GCC_C=C:\mingw64\bin\gcc
:: ar must come from the SAME x64 toolchain: a bare 'ar' can resolve to the
:: 32-bit MinGW.org binutils, whose archive the x86_64 ld cannot index
:: ("archive has no index"), breaking the fallback link.
if exist C:\mingw64\bin\ar.exe set AR=C:\mingw64\bin\ar
if exist C:\mingw64\bin\windres.exe set WINDRES=C:\mingw64\bin\windres
if not "%RANDOVERLAY_GCC%"=="" set GCC=%RANDOVERLAY_GCC%
if not "%RANDOVERLAY_GCC_C%"=="" set GCC_C=%RANDOVERLAY_GCC_C%
if not "%RANDOVERLAY_AR%"=="" set AR=%RANDOVERLAY_AR%
if not "%RANDOVERLAY_WINDRES%"=="" set WINDRES=%RANDOVERLAY_WINDRES%

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

:: --- Version metadata -------------------------------------------------------
:: VERSION at the repository root is the single source of truth; the release
:: workflow already refuses to build when it disagrees with the tag. A signed
:: binary has to carry a product name and version, so the layer gets a
:: VERSIONINFO resource built from the same numbers.
set RANDOVERLAY_VERSION=
if exist ..\VERSION for /f "usebackq delims=" %%v in ("..\VERSION") do set RANDOVERLAY_VERSION=%%v
if "%RANDOVERLAY_VERSION%"=="" (
    echo.
    echo   [ERROR] Could not read ..\VERSION. The layer would ship without
    echo   version metadata, which release signing requires.
    exit /b 1
)
for /f "tokens=1,2,3 delims=." %%a in ("%RANDOVERLAY_VERSION%") do (
    set VER_MAJOR=%%a
    set VER_MINOR=%%b
    set VER_PATCH=%%c
)
if "%VER_MINOR%"=="" set VER_MINOR=0
if "%VER_PATCH%"=="" set VER_PATCH=0
echo Version:   %RANDOVERLAY_VERSION%  (windres: %WINDRES%)
"%WINDRES%" -DRANDOVERLAY_VERSION_MAJOR=%VER_MAJOR% -DRANDOVERLAY_VERSION_MINOR=%VER_MINOR% -DRANDOVERLAY_VERSION_PATCH=%VER_PATCH% src\version.rc -o build\version.o
if errorlevel 1 (
    echo.
    echo   [ERROR] windres failed. Install the x86_64-w64-mingw32 binutils or
    echo   point RANDOVERLAY_WINDRES at windres.exe from the same toolchain.
    exit /b 1
)
echo.

:: === [1/4] RandOverlay implicit layer (PRIMARY) ==============================
echo [1/4] Building RandOverlay_layer.dll (implicit layer + ImGui)...
"%GCC%" -shared %BUILD_MODE% -std=c++17 ^
    -DWIN32_LEAN_AND_MEAN -DVK_NO_PROTOTYPES -DIMGUI_IMPL_VULKAN_NO_PROTOTYPES ^
    -I "%VKSDK%\Include" -I %IMGUI% -I %IMGUI%\backends -I src ^
    src\layer.cpp build\version.o ^
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
"%GCC_C%" -c %BUILD_MODE% -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\buffer.c     -o build\buffer.o
"%GCC_C%" -c %BUILD_MODE% -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\hook.c       -o build\hook.o
"%GCC_C%" -c %BUILD_MODE% -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\trampoline.c -o build\trampoline.o
"%GCC_C%" -c %BUILD_MODE% -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\hde\hde64.c  -o build\hde64.o
"%AR%" rcs build\libminhook.a build\buffer.o build\hook.o build\trampoline.o build\hde64.o
if errorlevel 1 goto fail
echo   MinHook OK
echo.

:: === [3/4] overlay.dll (injected-DLL FALLBACK) ==============================
echo [3/4] Building overlay.dll (fallback)...
"%GCC%" -shared %BUILD_MODE% -std=c++17 -DWIN32_LEAN_AND_MEAN ^
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
"%GCC%" %BUILD_MODE% -std=c++17 ^
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
if "%NO_PAUSE%"=="0" pause
exit /b 1

:end
if "%NO_PAUSE%"=="0" pause
