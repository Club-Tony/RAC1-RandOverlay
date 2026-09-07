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
- **Run (RAC1):** RPCS3 using its **Vulkan** renderer (the Windows default), plus the
  Archipelago **Text Client** writing to `C:\ProgramData\Archipelago\logs\`. RAC2/RAC3
  (PCSX2, named game clients) are not the supported product path yet.

Release users need only the Run requirements. Build requirements apply to contributors and
the release workflow, not to the precompiled ZIP/EXE.

## Build

### Windows

```bat
build.bat --no-pause
```

Produces `build\RandOverlay_layer.dll` (primary) and `build\overlay.dll` +
`build\injector.exe` (fallback). Add `--debug` for symbols and diagnostic builds.

### Linux

Vulkan layers are a Khronos mechanism, not a Windows one, so the same sources
build a Linux layer. Only the layer is supported there — the injected-DLL
fallback is Windows-only by construction.

```bash
sudo apt-get install -y build-essential cmake pkg-config \
  libvulkan-dev vulkan-tools mesa-vulkan-drivers libfontconfig1-dev

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```

Produces `build/libVkLayer_RandOverlay.so`. CMake also builds on Windows and is
the cross-platform equivalent of `build.bat` for the layer target alone.

Register it for the current user — no registry, no admin:

```bash
./install_layer.sh              # installs the .so and drops a manifest in
                                # ~/.local/share/vulkan/implicit_layer.d/
./install_layer.sh --status     # show registration + what the loader sees
./install_layer.sh --uninstall
```

**Linux differences**

- **RAC2 vs RAC3 must be chosen explicitly.** On Windows the layer reads
  PCSX2's window title to tell them apart; Wayland forbids reading another
  client's title and there is no portable replacement. Set `ActivePreset=RAC2`
  or `RAC3` in `RandOverlay.ini`. RAC1/RPCS3 is unaffected — it is unambiguous
  by process name.
- **Fonts.** `HandelGothic BT` and `Bahnschrift` are Windows-installed and do
  not exist on Linux. The ini ships `FontFamilyLinux` / `FontFallbackLinux`
  defaults; point `FontFileLinux` at an absolute `.ttf`/`.otf` to use the real
  font if you have it.
- **No launch prompt.** If Archipelago is not running the layer logs it rather
  than opening a dialog — a modal window spawned from inside `vkQueuePresentKHR`
  has no reliable always-on-top under a compositor.
- **Flatpak.** A sandboxed RPCS3/PCSX2 cannot see `~/.local/share/vulkan` or
  your Archipelago logs by default. `install_layer.sh` detects this and prints
  the `flatpak override` command you need.
- **Never set `VK_ADD_IMPLICIT_LAYER_PATH`** while the manifest is installed in
  a standard search directory. Two discovery routes for one layer make the
  loader load it twice and crash the host.

## One-click installer

End users should not assemble this folder. The download is a **single BAT at the
repository root**: `Install-RandOverlay.bat`. Double-click it from anywhere (Downloads,
Desktop, a USB stick). It does not need `Setup-RandOverlay.ps1` sitting next to it.

That root file is generated, not hand-edited. `installer/Build-RandOverlayRelease.ps1`
builds a deterministic ZIP of the compiled layer DLL plus the setup scripts, then wraps
the ZIP in the BAT:

1. A short CMD stub (`title RAC RandOverlay Setup`).
2. A `#===EXTRACTOR===` marker and a small PowerShell extractor.
3. A `#===PAYLOAD===` marker and the ZIP as **Base64**. Base64 is packaging so the ZIP
   can live inside a text `.bat`. It is not encryption or a signature.
4. The **SHA-256 of the decoded ZIP bytes** is baked into the stub (not a hash of the
   Base64 text).

On double-click the BAT:

- writes the extractor to `%TEMP%` and runs it against itself (`%~f0`)
- finds `#===PAYLOAD===`, Base64-decodes the ZIP, hashes it
- **stops before touching the disk** if the marker is missing, the Base64 is truncated,
  or the SHA-256 does not match (exit `9`)
- extracts to a unique temp folder, clears Mark-of-the-Web on those files, runs
  `Setup-RandOverlay.ps1`, then deletes that temp folder

`Setup-RandOverlay.ps1` is the real wizard: pick games (RAC1 default), check only the
dependencies those games need, install per-user under `%LOCALAPPDATA%\RandOverlay`,
register one Vulkan implicit layer at
`HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers` (no admin), and copy the setup
engine + `lib\` so Status / Repair / Uninstall keep working. It does not bundle
Lawrence, firmware, the game, Archipelago, or RPCS3. No telemetry.

Install once. After that the overlay loads by itself the next time you start RPCS3
with the **Vulkan** renderer (RPCS3's usual Windows default) — no Startup entry and
no extra overlay process. Keep the Archipelago **Text Client** running while you play
so there is a log to read. RAC2/RAC3 remain experimental and are not this edition's
supported path on `main`.

If RPCS3, PCSX2, or Archipelago is missing or in an unusual folder, the wizard
does **not** guess. It prints `[MISSING]`, offers Recheck, an official download
link, **[P] Set custom path** (browse to `rpcs3.exe` / `pcsx2-qt.exe` /
Archipelago's folder), or Save and exit and Repair later. It only auto-looks in
`%LOCALAPPDATA%\Programs\RPCS3`, `%ProgramFiles%\RPCS3`, the same for PCSX2,
`C:\ProgramData\Archipelago`, PATH, and a *currently running* emulator process.
A portable copy on the Desktop is found via [P] (or if RPCS3 is already open).
Firmware, the ISO/PKG, and the multiplayer client are reported on the stack rows
but do not block installing the layer.

Two different files share the name `Install-RandOverlay.bat`:

| File | What it is |
| --- | --- |
| **Repo root** `Install-RandOverlay.bat` | One-click carrier. **This is the file to download.** |
| `installer/Install-RandOverlay.bat` | Tiny launcher **inside** the ZIP. Only starts `Setup-RandOverlay.ps1` in the same folder. Useless by itself. |

The transparent ZIP (`RandOverlay-Vulkan-vX.Y.Z.zip`) is the same payload without Base64,
for people who want to inspect files. After extracting it, run the *inner* `Install-RandOverlay.bat`
that sits next to `Setup-RandOverlay.ps1`.

Rebuild the one-click BAT after a layer or installer change:

```powershell
.\build.bat --no-pause
.\installer\Build-RandOverlayRelease.ps1 -Format Bat,Zip
copy .\dist\RandOverlay-Setup-vX.Y.Z.bat ..\Install-RandOverlay.bat
```

An optional setup EXE can embed the same ZIP; it is unsigned and is not the primary
download.

## Install / uninstall (after the wizard has run)

```powershell
.\Setup-RandOverlay.ps1 -Action Status
.\Setup-RandOverlay.ps1 -Action Repair
.\Setup-RandOverlay.ps1 -Action Configure -Games RAC1
.\Setup-RandOverlay.ps1 -Action CheckForUpdates
.\Setup-RandOverlay.ps1 -Action Uninstall
```

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

1. Start the Archipelago **Text Client** (RAC1 uses this generic client, not the
   named RAC2/RAC3 clients).
2. Launch RPCS3 with the Vulkan renderer (default on Windows) and boot RAC1.
3. Trigger or wait for an Archipelago event — the text appears over the frame.

## Configuration

Reads **`RandOverlay.ini`** (`EnabledPresets`, fallback `ActivePreset`, and `[Preset.<name>]`).
The installed layer selects RAC1 from RPCS3 automatically. RAC2/RAC3 (PCSX2 plus the
named Archipelago game clients) remain in the sources but are not the supported
product path on `main` — they are less tested, and those clients use different
window titles than the generic Archipelago **Text Client** RAC1 uses.

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
- `FontFamily` / `FontFallback` — resolved via the Windows font registry, or via
  fontconfig on Linux, and loaded into ImGui (HandelGothic BT → Bahnschrift →
  built-in). The primary font supplies letters while fallback digits keep values
  such as `RAC1` visually distinct from `RACI`
- `FontFile` — absolute path to a `.ttf`/`.otf`, bypassing family resolution
  entirely. `FontFileWindows` / `FontFileLinux` / `FontFamilyLinux` /
  `FontFallbackLinux` let one shared ini serve both builds
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
app. It **self-disables** in any process that is not `rpcs3`, `pcsx2-qt`, or
`pcsx2` (with or without a `.exe` suffix, so the same list covers both
platforms), making it harmless to leave registered.

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

- `../Install-RandOverlay.bat` (repo root) - generated one-click BAT: Base64-embedded ZIP + SHA-256 check. Download this.
- `installer/Install-RandOverlay.bat` - inner ZIP launcher only (runs `Setup-RandOverlay.ps1` beside it).
- `installer/Setup-RandOverlay.ps1` - guided install and maintenance engine.
- `installer/Build-RandOverlayRelease.ps1` - builds the ZIP and wraps it as the root one-click BAT.
- `tests/installer/Test-Installer.ps1` - isolated installer lifecycle regression.

- `src/layer.cpp` — the implicit layer (present interception + ImGui text).
- `src/layer_dispatch.h` — per-instance / per-device dispatch tables.
- `src/platform.h` — Win32/POSIX abstraction; the only file with an OS split
  beyond the three call sites it wraps.
- `src/config.h` — shared `RandOverlay.ini` reader.
- `src/process_gate.h` — emulator process gate.
- `src/log_reader.h` — tails the Archipelago log for events.
- `src/font_resolver.h` — family → font file (Windows registry / fontconfig).
- `src/overlay.cpp`, `src/injector.cpp` — injected-DLL fallback (Windows only).
- `RandOverlay_layer.json` — Windows layer manifest.
- `RandOverlay_layer.json.in` — manifest template; CMake and `install_layer.sh`
  fill in the built library's absolute path.
- `install_layer.bat` / `uninstall_layer.bat` — Windows registration.
- `install_layer.sh` — Linux registration (`--status`, `--uninstall`).
- `build.bat` — Windows build of everything (x86_64 guard, `--no-pause`, `--debug`).
- `CMakeLists.txt` — cross-platform build of the layer + unit tests.
