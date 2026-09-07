# RAC1-RandOverlay

Archipelago overlay for Ratchet & Clank 1 (RPCS3). Displays game events as a translucent text overlay positioned over the RPCS3 window.

Works with RPCS3 in both windowed and fullscreen mode.

### Optional Hotkeys
- **Ctrl+Alt+A** — Toggle overlay on/off (ON by default)
- **Ctrl+Alt+F** — Toggle font (HandelGothic BT / Bahnschrift)
- **Ctrl+Esc** — Reload script (AHK version only)

## AHK Version
Simply download and run `RandOverlay.ahk` with Archipelago Text Client active (Requires AutoHotkey v1 to be installed).

## PowerShell + WPF Version
Keep `RandOverlay.bat` and `RandOverlay.ps1` in the same folder, run the `.bat` with Archipelago Text Client active.

## Vulkan DLL Version
Download and run `Install-RandOverlay.bat` once. After that it loads automatically when you start RPCS3 with the Vulkan renderer — no Startup shortcut and nothing else to launch. Keep the Archipelago Text Client (or the RAC1 client) running so there are events to show. This version draws inside the emulator frame, so it is the one to use for exclusive fullscreen play — the AHK and PowerShell + WPF editions may not display correctly in fullscreen.
