# RandOverlay — Vulkan Overlay

Draws Archipelago randomizer event text **inside the emulator's rendered frame**
by hooking `vkQueuePresentKHR`. Because it works at the Vulkan present layer, it
shows up in **exclusive fullscreen, borderless, and windowed** alike — unlike the
AHK / PS+WPF window overlays, which a top-most window cannot paint over an
exclusive-fullscreen swapchain.

Two mechanisms are provided:

| Mechanism | File | When to use |
| --- | --- | --- |
| **Implicit Vulkan layer** (primary) | `build\RandOverlay_layer.dll` | Recommended. Sits in the Vulkan dispatch chain, so it reliably intercepts present in any display mode. Registered once per user. |
| **Injected DLL** (fallback) | `build\overlay.dll` + `build\injector.exe` | No registry footprint. Note: late injection into an already-running emulator often can't catch present calls it already resolved — treat as experimental. |

Rendering uses Dear ImGui's Vulkan backend (`deps/imgui`). Text style comes from
the shared repo-root `RandOverlay.ini`, so all three runtimes look consistent.

## Requirements

- **Build:** an **x86_64** MinGW-w64 `g++` (e.g. `C:\mingw64\bin`, GCC 13+), and the
  Vulkan SDK (`build.bat` expects `C:\VulkanSDK\1.4.341.1`). A 32-bit toolchain
  will not produce a DLL that loads into the emulator — `build.bat` guards against this.
- **Vendored deps (not committed):** clone into `deps/` before building:
  `git clone https://github.com/ocornut/imgui deps/imgui` and
  `git clone https://github.com/TsudaKageyu/minhook deps/minhook` (minhook is only
  needed for the injected-DLL fallback).
- **Run:** RPCS3 (RAC1) or PCSX2 (RAC2/RAC3) using the **Vulkan** renderer, plus a
  running Archipelago client writing to `C:\ProgramData\Archipelago\logs\Launcher_*.txt`.

Release users need only the Run requirements. Build requirements apply to contributors and
the release workflow, not to the precompiled ZIP/EXE.

## Build

```bat
build.bat --no-pause
```

Produces `build\RandOverlay_layer.dll` (primary) and `build\overlay.dll` +
`build\injector.exe` (fallback). Add `--debug` for symbols and diagnostic builds.

## Install / uninstall (release package)

For the one-file path, download and double-click `RandOverlay-Setup-vX.Y.Z.bat`. It embeds,
SHA-256 verifies, and temporarily extracts the same versioned release ZIP before handing off
to guided setup.

For the transparent package path, extract the official release ZIP and double-click:

```bat
Install-RandOverlay.bat
```

Advanced users can invoke the setup engine directly:

```powershell
powershell -NoProfile -File .\Setup-RandOverlay.ps1
```

Guided setup defaults to RAC1 and permits any combination of RAC1, RAC2, and RAC3. It
installs to `%LOCALAPPDATA%\RandOverlay`, checks only dependencies needed by the selected
games, and registers one canonical per-user manifest. Re-running setup is safe.

```powershell
.\Setup-RandOverlay.ps1 -Action Status
.\Setup-RandOverlay.ps1 -Action Repair
.\Setup-RandOverlay.ps1 -Action Configure -Games RAC1,RAC2
.\Setup-RandOverlay.ps1 -Action CheckForUpdates
.\Setup-RandOverlay.ps1 -Action Uninstall
```

No telemetry is sent. Dependency links and update checks occur only after an explicit user
action. The optional EXE embeds and verifies the same ZIP before launching setup.

## Developer registration helper

```bat
install_layer.bat     :: registers the implicit layer under HKCU (no admin)
uninstall_layer.bat   :: removes it
```

Registration adds `RandOverlay_layer.json` to
`HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers`. The layer then auto-loads the next
time a supported emulator starts. These BAT files are for source-tree development; release
users should use the idempotent setup tool, which cleans stale owned registrations and
preserves unrelated Vulkan layers.

## Usage

1. Start the Archipelago Text Client (or a game-specific client).
2. Launch RPCS3 / PCSX2 with the Vulkan renderer and boot the game.
3. Trigger or wait for an Archipelago event — the text appears over the frame.

## Configuration

Reads **`RandOverlay.ini`** (`EnabledPresets`, fallback `ActivePreset`, and `[Preset.<name>]`).
The installed layer selects RAC1 from RPCS3 automatically. For PCSX2, it prefers the running
game title and falls back to the Archipelago client title to distinguish RAC2 from RAC3. If the
signals are missing or conflict, event rendering pauses rather than choosing the wrong preset.

- `OverlayColor`, `BackgroundColor` — `#RRGGBB`
- `VerticalPercent` — 0 (top) … 1 (bottom); overlay top edge, centered horizontally
- `VulkanFontSize` — 1080p text-size baseline; the layer applies moderated
  height-based scaling (36px at 720p, 48px at 1080p, 60px at 1440p, and
  72px at 4K with the shipped 48px baseline)
- `DisplayMs` — how long each message stays up
- `FadeInMs` / `FadeOutMs` — fade durations (same lifecycle as the AHK/PS overlays)
- `PollMs` — Archipelago log poll cadence
- `EnabledPresets` — installer-managed allow-list for automatic runtime selection
- `ActivePreset` — backward-compatible fallback; not an initial-game prompt
- `EmulatorProcesses` — process mapping for each detected preset
- `FontFamily` / `FontFallback` — resolved via the Windows font registry and loaded;
  the primary font supplies letters while fallback digits keep values such as `RAC1`
  visually distinct from `RACI`
  into ImGui (HandelGothic BT → Bahnschrift → built-in)
- `ClientComponent` — which Archipelago Launcher component the launch prompt starts
  for this preset (RAC1: `Ratchet & Clank Client`, RAC2/RAC3: the R&C game clients)

If Archipelago is not running when the overlay activates, a one-time prompt offers:
**Yes** = launch the automatically detected preset's client directly, **No** = open the Archipelago
Launcher to pick any installed client (RAC1/RAC2/RAC3/etc.), **Cancel** = do nothing.
Suppress with `RANDOVERLAY_NO_PROMPT=1`.

Display behavior matches the AHK and PS+WPF runtimes: newest `*.txt` log excluding
`Generate_`/`Server_`, a one-time "Archipelago Overlay ready" startup notice, fade
in → hold `DisplayMs` → fade out, single auto-sized line (wrapping only if wider
than ~92% of the frame).

Override the ini location with the `RANDOVERLAY_INI` environment variable.

## Automated live verification

The live runner builds deterministic `rpcs3.exe` and `pcsx2-qt.exe` mock hosts, uses only
scratch configuration/logs, injects synthetic events, verifies process and preset gating,
checks clean validation/OBS coexistence, and captures pre/post-event PNGs with overlay-band
pixel assertions.

```powershell
.\tests\run_live_tests.ps1 -Mode preflight
.\tests\run_live_tests.ps1 -Mode all -KeepArtifacts
.\tests\run_live_tests.ps1 -Mode validation
.\tests\run_live_tests.ps1 -Mode visual
```

Artifacts are written under `tests\live\artifacts` and are gitignored. Real RPCS3/PCSX2
game launching remains a manual certification step because game paths and emulator state
are machine-specific.

## Safety / scope

The layer is registered as `GLOBAL`, so the loader offers it to **every** Vulkan
app. It **self-disables** in any process that is not `rpcs3.exe`, `pcsx2-qt.exe`,
or `pcsx2.exe`, so leaving it registered is harmless for other apps.

Kill switch: set `DISABLE_RANDOVERLAY=1` to disable without unregistering.

## Troubleshooting

Check `build\layer_debug.log` (written next to the DLL). A healthy run shows the
full chain:

```
=== RandOverlay Layer loaded ===
vkCreateInstance OK ...
vkCreateDevice OK ...
vkCreateSwapchainKHR entry ...
Swapchain: N images ...
Message: <event text>
```

- Stops after `vkCreateDevice` with no `vkCreateSwapchainKHR`: the game isn't
  presenting through Vulkan yet — confirm the **Vulkan** renderer is selected and a
  game is actually rendering.
- `disabled=1`: the host process isn't a supported emulator, or
  `DISABLE_RANDOVERLAY=1` is set.
- No text but chain is complete: confirm the Archipelago client is logging to the
  configured `LogDir` and the event matches the interest filter in `log_reader.h`.

## Files

- `installer/Install-RandOverlay.bat` - double-click release ZIP entrypoint.
- `installer/Setup-RandOverlay.ps1` - guided install and maintenance engine.
- `installer/Build-RandOverlayRelease.ps1` - deterministic self-contained BAT/ZIP/EXE release builder.
- `tests/installer/Test-Installer.ps1` - isolated installer lifecycle regression.

- `src/layer.cpp` — the implicit layer (present interception + ImGui text).
- `src/layer_dispatch.h` — per-instance / per-device dispatch tables.
- `src/config.h` — shared `RandOverlay.ini` reader.
- `src/process_gate.h` — emulator process gate.
- `src/log_reader.h` — tails the Archipelago log for events.
- `src/overlay.cpp`, `src/injector.cpp` — injected-DLL fallback.
- `RandOverlay_layer.json` — layer manifest.
- `install_layer.bat` / `uninstall_layer.bat` — registration.
- `build.bat` — builds everything (with x86_64 guard, `--no-pause`, and `--debug`).
