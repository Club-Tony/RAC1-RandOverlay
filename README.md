# RAC1-RandOverlay

Archipelago event overlay for Ratchet & Clank randomizer play. The project name is still RAC1-focused, but this branch adds experimental preset support for RAC1, RAC2, and RAC3.

The overlay reads Archipelago client logs and displays matching game events as a translucent, click-through text overlay positioned over the active emulator window.

## Support Status

| Game | Default emulator process | Status |
| --- | --- | --- |
| RAC1 | `rpcs3.exe` | Existing/default path |
| RAC2 | `pcsx2-qt.exe`, `pcsx2.exe` | Experimental |
| RAC3 | `pcsx2-qt.exe`, `pcsx2.exe` | Experimental |

RPCS3 and PCSX2 window behavior can differ, especially in fullscreen and borderless modes. RAC2/RAC3 support should be treated as early tester support until more setups are validated.

## Quick Start

1. Start Archipelago Text Client or a game-specific Archipelago client.
2. Edit `RandOverlay.ini` and set `ActivePreset=RAC1`, `RAC2`, or `RAC3`.
3. Run one overlay version:
   - AHK: run `RandOverlay.ahk` with AutoHotkey v1 installed.
   - PowerShell/WPF: run `PS+WPF-Version/RandOverlay.bat`.
4. Trigger or wait for an Archipelago event.

If `RandOverlay.ini` is missing or has invalid values, both runtimes fall back to built-in RAC1-compatible defaults and show/log a short warning.

## Configuration

`RandOverlay.ini` is shared by both runtime versions. The default is `ActivePreset=RAC1`.

Each preset controls:

- `DisplayName`
- `EmulatorProcesses`
- `OverlayColor`
- `BackgroundColor`
- `VerticalPercent`
- `FontFamily` and `FontFallback`
- `AhkFontSize` and `WpfFontSize`

Colors use RGB hex values such as `#80A0D0`. AHK converts those internally for the Win32 text-color APIs.

## Hotkeys

- `Ctrl+Alt+A` - Toggle overlay on/off.
- `Ctrl+Alt+F` - Toggle configured primary/fallback font.
- `Ctrl+Alt+B` - Toggle borderless fullscreen on the detected emulator window.
- `Ctrl+Esc` - Reload script (AHK version only).

## Feedback

Short tester feedback is tracked through GitHub Issues so it can be triaged into TODOs later:

[Submit overlay feedback](https://github.com/Club-Tony/RAC1-RandOverlay/issues/new?template=feedback.yml)

The feedback form asks for a short summary, game, runtime, feedback type, optional details, and optional screenshots/logs/config snippets. The link works once the issue form is merged into the repository's default branch.

## Validation

Run the local validation script before committing overlay changes:

```powershell
.\Test-RandOverlay.ps1
```

It checks Git whitespace, PowerShell syntax, GitHub issue form shape, AutoHotkey `/iLib` syntax, and a short AHK startup self-test using a temporary Archipelago log directory. Use `-SkipAhkRuntime` if you only want non-GUI checks.

GitHub Actions runs the same validation on push and pull request events, with `-SkipAhkRuntime` because hosted runners are not reliable for overlay window smoke tests.

The Vulkan renderer has a repo-local live suite that uses scratch configuration and logs,
synthetic events, deterministic mock emulator windows, Khronos validation, and screenshot
region assertions:

```powershell
.\Vulkan-DLL-Version\tests\run_live_tests.ps1 -Mode preflight
.\Vulkan-DLL-Version\tests\run_live_tests.ps1 -Mode all -KeepArtifacts
```

From the [internal] workspace, the same suite is available through the optional native-window
target `python tests\live\run_live_tests.py rac-overlay --fixture mock --keep-artifacts`.
It is intentionally excluded from `all` and scheduled sweeps because it opens Vulkan windows.

## Smoke-Test Checklist

- AHK and PowerShell/WPF are owner-confirmed across RAC1-RAC3 and retain automated regression coverage.
- The Vulkan mock suite verifies RAC1/RPCS3 windowed and RAC2/PCSX2 borderless in-frame rendering.
- Real-emulator Vulkan certification remains required for windowed, borderless, and exclusive fullscreen where available.
- `Ctrl+Alt+A` toggles overlay visibility.
- `Ctrl+Alt+F` toggles between configured fonts.
- `Ctrl+Alt+B` toggles borderless mode and restores the original window.
- Missing or invalid `RandOverlay.ini` falls back to RAC1 defaults without blocking startup.

## Future Naming

The repo name may eventually be generalized after RAC2/RAC3 behavior is validated across more setups. For now, the repo keeps the existing `RAC1-RandOverlay` name while documenting broader experimental support.
