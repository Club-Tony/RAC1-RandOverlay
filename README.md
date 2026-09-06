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
2. Run one overlay version:
   - AHK: set `ActivePreset=RAC1`, `RAC2`, or `RAC3` in `RandOverlay.ini`, then run `RandOverlay.ahk` with AutoHotkey v1 installed.
   - PowerShell/WPF: set `ActivePreset` in `RandOverlay.ini`, then run `PS+WPF-Version/RandOverlay.bat`.
   - Vulkan: select the games during one-click setup; the layer detects the running supported game and switches among the enabled presets automatically.
3. Trigger or wait for an Archipelago event.

If `RandOverlay.ini` is missing or has invalid values, both runtimes fall back to built-in RAC1-compatible defaults and show/log a short warning.

## Vulkan Release Installation

The Vulkan version draws inside the emulator frame and is intended for exclusive fullscreen.
Tagged releases publish a self-contained setup BAT as the primary download, plus the same
payload as a transparent ZIP and an optional setup EXE;
end users do not need build tools.

1. Download only from the official GitHub Releases page and verify `SHA256SUMS.txt`.
2. Double-click `RandOverlay-Setup-vX.Y.Z.bat`. It contains, verifies, and automatically
   installs the current `RandOverlay-Vulkan-vX.Y.Z.zip` payload.
3. Alternatively, extract the ZIP and double-click its `Install-RandOverlay.bat`, or use the
   optional `RandOverlay-Setup-vX.Y.Z.exe`.
4. Select one or more games. RAC1 is selected by default.
5. Follow the dependency checks, then launch the selected emulator with Vulkan.

| Selection | Emulator checked by setup | Archipelago client checked by setup |
| --- | --- | --- |
| RAC1 (default) | RPCS3 | Ratchet & Clank Client |
| RAC2 | PCSX2 | Ratchet & Clank 2 Client |
| RAC3 | PCSX2 | Ratchet and Clank 3 Client |

Setup installs under `%LOCALAPPDATA%\RandOverlay`, supports Status, Repair, Configure,
Check for updates, and Uninstall, and sends no telemetry. Missing dependencies get a
confirmed allowlisted WinGet option where available or a clickable official link followed by
Recheck/Save-and-exit. Multi-game selections are stored as `EnabledPresets`; no initial active
game choice is required. RPCS3 resolves RAC1 directly, while PCSX2 uses the running game or
Archipelago client window title to distinguish RAC2 from RAC3 and pauses rather than guessing.

For RAC1, Status and Preflight also check the wider Archipelago stack: the Archipelago version,
which pinned release of the RAC1 apworld is installed, and whether RPCS3 has firmware, the game,
the multiplayer PKG and networking enabled. Setup can install or adopt three things from a
pinned, checksummed manifest, each with backup and rollback: the RAC1 apworld, a portable copy
of PopTracker kept under the install root, and the multiplayer PKG, which is verified and then
handed to you to install in RPCS3 rather than written into it.

Setup can also set RPCS3's network status to Connected, but only through an explicit action
that backs up `config.yml` first and changes nothing else, and it can launch Archipelago,
RPCS3, PopTracker or a Lawrence build you point it at. Firmware, the game and Lawrence always
come from you; nothing else is ever bundled or downloaded.

Until trusted signing is active, Windows may show an Unknown Publisher or SmartScreen
reputation warning. This can occur because the project is unsigned or has not established
reputation; it is not described as a guaranteed false positive. Proceed only with an
official release whose SHA-256 matches the published checksum.

See [Vulkan setup details](Vulkan-DLL-Version/README.md), [privacy](PRIVACY.md),
[release signing](SIGNING.md), and the [code signing policy](CODE-SIGNING-POLICY.md).

## Configuration

`RandOverlay.ini` is shared by all runtime versions. `ActivePreset=RAC1` remains the manual
selection for AHK/PowerShell and the Vulkan fallback. Installed Vulkan configurations also use
`EnabledPresets` as the runtime auto-detection allow-list.

Each preset controls:

- `DisplayName`
- `EmulatorProcesses`
- `OverlayColor`
- `BackgroundColor`
- `VerticalPercent`
- `FontFamily` and `FontFallback`
- `AhkFontSize`, `WpfFontSize`, and the resolution-scaled `VulkanFontSize`

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

The Vulkan installer lifecycle suite is also available directly:

```powershell
.\Vulkan-DLL-Version\tests\installer\Test-Installer.ps1
```

GitHub Actions runs the same validation on push and pull request events, with `-SkipAhkRuntime` because hosted runners are not reliable for overlay window smoke tests.

## Public Repository Hygiene

This public repository contains only product source and user-facing documentation. Keep
planning documents, session notes, local assistant configuration, instruction files, and
machine-specific paths out of commits.

Before committing or pushing:

- Stage explicit product paths; do not use broad staging commands.
- Review both `git diff --cached --name-status` and `git diff --cached`.
- Use a human author/committer identity and omit automated-tool attribution or
  automated-tool/agent co-author trailers.
- Keep private workflow metadata under the ignored paths in `.gitignore`.

The Vulkan renderer has a repo-local live suite that uses scratch configuration and logs,
synthetic events, deterministic mock emulator windows, Khronos validation, and screenshot
region assertions:

```powershell
.\Vulkan-DLL-Version\tests\run_live_tests.ps1 -Mode preflight
.\Vulkan-DLL-Version\tests\run_live_tests.ps1 -Mode all -KeepArtifacts
```

On Linux, the equivalent suite is `./Vulkan-DLL-Version/tests/run_live_tests.sh all`,
which runs headlessly under `xvfb-run` and asserts on the presented frame directly.

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
