@echo off
REM ============================================================================
REM RandOverlay tests
REM
REM   run_tests.bat            -> build + run the headless unit tests
REM                               (ini reader, process gate, Archipelago log parser)
REM
REM The VISUAL test (tests\mock_vk_host.cpp) is a separate, interactive harness:
REM it is a mock Vulkan host you build AS rpcs3.exe so the implicit layer activates,
REM then you register the layer (install_layer.bat) and run it to see the overlay
REM draw over its window. See the header of mock_vk_host.cpp for details.
REM ============================================================================
setlocal
set HERE=%~dp0
set PROJ=%HERE%..
set GCC=g++
if exist C:\mingw64\bin\g++.exe set GCC=C:\mingw64\bin\g++
set INI=%PROJ%\..\RandOverlay.ini

if not exist "%PROJ%\build" mkdir "%PROJ%\build"

echo [1/1] Building test_units.exe...
"%GCC%" -O2 -std=c++17 -DWIN32_LEAN_AND_MEAN -I "%PROJ%\src" ^
    "%HERE%test_units.cpp" -o "%PROJ%\build\test_units.exe" ^
    -lkernel32 -luser32 -lshell32 -ladvapi32 -static -static-libgcc -static-libstdc++
if errorlevel 1 ( echo BUILD FAILED & exit /b 1 )

echo.
"%PROJ%\build\test_units.exe" "%INI%"
exit /b %errorlevel%
