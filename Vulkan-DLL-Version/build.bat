@echo off
title RandOverlay Vulkan Build
echo ============================================
echo   Building RandOverlay Vulkan DLL
echo ============================================
echo.

set VKSDK=C:\VulkanSDK\1.4.341.1
set MINHOOK=deps\minhook
set GCC=g++

echo [1/3] Building MinHook...
gcc -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\buffer.c -o build\buffer.o
gcc -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\hook.c -o build\hook.o
gcc -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\trampoline.c -o build\trampoline.o
gcc -c -O2 -DWIN32_LEAN_AND_MEAN -I %MINHOOK%\include %MINHOOK%\src\hde\hde64.c -o build\hde64.o
ar rcs build\libminhook.a build\buffer.o build\hook.o build\trampoline.o build\hde64.o
if errorlevel 1 goto fail
echo   MinHook OK

echo [2/3] Building overlay.dll...
%GCC% -shared -O2 -std=c++17 -DWIN32_LEAN_AND_MEAN ^
    -I %VKSDK%\Include ^
    -I %MINHOOK%\include ^
    -I src ^
    src\overlay.cpp ^
    -o build\overlay.dll ^
    -L build -lminhook ^
    -L %VKSDK%\Lib -lvulkan-1 ^
    -lkernel32 -luser32 -lpsapi ^
    -static-libgcc -static-libstdc++ ^
    -Wl,--kill-at
if errorlevel 1 goto fail
echo   overlay.dll OK

echo [3/3] Building injector.exe...
%GCC% -O2 -std=c++17 -DWIN32_LEAN_AND_MEAN ^
    src\injector.cpp ^
    -o build\injector.exe ^
    -lkernel32 -luser32 -lpsapi ^
    -static-libgcc -static-libstdc++
if errorlevel 1 goto fail
echo   injector.exe OK

echo.
echo ============================================
echo   Build complete!
echo   Output: build\injector.exe + build\overlay.dll
echo ============================================
goto end

:fail
echo.
echo   BUILD FAILED - check errors above
:end
pause
