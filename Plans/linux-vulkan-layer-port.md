# Linux Vulkan Layer Port

**Status:** Awaiting Manual Action
**Created:** 2026-08-12

## Context

All three overlay runtimes were Windows-only. AutoHotkey has no Linux
equivalent and WPF is .NET Framework, so neither of those ports is possible.
The Vulkan layer is different: Vulkan layers are a Khronos mechanism that works
identically on Linux, and layer discovery there is simpler than on Windows —
a JSON manifest in `~/.local/share/vulkan/implicit_layer.d/` replaces
registry registration under `HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers`.

The layer also never touches the emulator process: it tails an Archipelago log
file, so the data layer carried over unchanged. Measured Win32 surface before
the port was ~39 call sites across ~1,500 lines, with `layer_dispatch.h` and
`overlay_layout.h` at zero.

## What shipped

**New:** `src/platform.h` — the entire platform abstraction. Everything else
uses `std::filesystem`, `std::chrono` and `std::getenv`, so only three
functions are genuinely per-platform: `selfExePath()` (`GetModuleFileNameA`
vs `/proc/self/exe`), `moduleDir()` (`GetModuleHandleEx` vs `dladdr`), and
`processRunningWithPrefix()` (Toolhelp vs a `/proc` scan).

**Ported:** `config.h`, `log_reader.h`, `process_gate.h`, `font_resolver.h`,
`arch_client_check.h`, `layer.cpp`. The Vulkan dispatch chain, present hook,
semaphore handoff, fade math, layout scaling and mixed-font digit rendering
were not touched.

**Build:** `CMakeLists.txt` builds both platforms from one source set;
`RandOverlay_layer.json.in` + `install_layer.sh` replace the registry step;
`.github/workflows/validate-linux.yml` builds and tests on `ubuntu-latest`
under lavapipe.

**Not ported, deliberately:** `RandOverlay.ahk`, `PS+WPF-Version/`, and the
injected-DLL fallback (`overlay.cpp`, `injector.cpp`, MinHook) — the last is
Windows-only by construction and already documented as broken and unshipped.

### Three decisions worth remembering

1. **`.exe` suffix normalization** (`process_gate.h`). Linux binaries are
   `rpcs3`, not `rpcs3.exe`. Rather than fork the process lists, both sides of
   every comparison are stripped in `listContains`, so one set of literals
   serves both platforms and the ini needs no per-OS process names.

2. **fontconfig always substitutes.** `FcFontMatch` never fails — asking for a
   font that is not installed returns something else. `resolveViaFontconfig`
   therefore verifies the matched family against the request and returns `""`
   on mismatch. Without that check a Linux user asking for `HandelGothic BT`
   would silently get DejaVu Sans. The ini now also carries
   `FontFamilyLinux`/`FontFallbackLinux`/`FontFileLinux`.

3. **RAC2/RAC3 disambiguation is gone on Linux.** It relied on `EnumWindows`
   reading PCSX2's window title, which Wayland forbids by design. The collector
   is behind `#ifdef _WIN32`; on Linux the layer falls back to the ini's
   `ActivePreset` and logs why once. RAC1/RPCS3 is unaffected — unambiguous by
   process name.

## Verification

Verified on Ubuntu 22.04 (WSL2), GCC 11.4, CMake 3.22, Vulkan headers 1.3.204,
Mesa 23.2 lavapipe.

| Step | State |
|---|---|
| Windows unit tests (86, was 34) | **Passing** — `86 passed, 0 failed` |
| Windows layer builds, 3 entry points exported | **Passing** — no regression |
| Linux build (`libVkLayer_RandOverlay.so`) | **Passing** — clean, fontconfig detected |
| Linux unit tests | **Passing** — `86 passed, 0 failed`, ctest green |
| Exports unmangled, only the 9 intended symbols visible | **Passing** |
| Loader enumerates the layer | **Passing** — `vulkaninfo` lists `VK_LAYER_RANDOVERLAY_overlay` |
| Self-disables in a non-emulator | **Passing** — `process=vulkaninfo … targeted=0, disabled=1` |
| Activates for a suffixless `rpcs3` | **Passing** — `process=rpcs3 … targeted=1, disabled=0`, RAC1 preset resolved |
| Installed layer resolves ini + a Linux log dir | **Passing** — `logDir=~/.local/share/Archipelago/logs` |
| Overlay actually renders into the presented frame | **Passing** — readback shows 0 differing pixels with the layer disabled vs 26964 with an event |
| Khronos validation over a real present loop | **Passing** — validation confirmed loaded, zero errors |
| Repeated swapchain rebuild (per-swapchain lifecycle) | **Passing** — 4 rebuilds, layer re-initialised on all, zero validation errors |
| Linux CI (`ubuntu-latest`, Xvfb + lavapipe) | **Passing** — 15/15 live tests, same pixel counts as local |
| Real RPCS3 + RAC1, windowed and exclusive fullscreen | **Not started** — needs a Linux box or a VM with GPU passthrough; cannot be done in WSL2 |

Reproduce with:

```
cmake -S Vulkan-DLL-Version -B Vulkan-DLL-Version/build/linux -DCMAKE_BUILD_TYPE=Release
cmake --build Vulkan-DLL-Version/build/linux -j
ctest --test-dir Vulkan-DLL-Version/build/linux --output-on-failure
Vulkan-DLL-Version/install_layer.sh --build-dir build/linux
```

### Three bugs the live run caught

All three build, install and start cleanly, then fail silently — which is why
none would have been found by inspection.

1. **C++-mangled entry points.** `vulkan/vk_layer.h` already defines
   `VK_LAYER_EXPORT` on Linux, without `extern "C"`, so the original
   `#ifndef` guard was skipped and the exports came out as
   `_Z31RandOverlay_GetInstanceProcAddr…`. The loader `dlsym`s the exact
   unmangled names from the manifest, so the layer would simply never
   activate. Now `#undef`'d and defined unconditionally.
2. **Windows `LogDir` adopted on Linux.** The shared ini sets
   `LogDir=C:\ProgramData\…`, which overrode the platform probe — the overlay
   would tail a path that cannot exist and never fire. Windows-shaped paths
   are now rejected on Linux, with `LogDirLinux` as the explicit override.
3. **Installed layer had no ini.** `install_layer.sh` placed only the `.so`,
   so the layer resolved no config and ran on built-in defaults. It now
   installs `RandOverlay.ini` alongside, and never overwrites an existing one.

Also fixed: `*.sh text eol=lf` in `.gitattributes`. With `core.autocrlf=true`
this repo would otherwise check `install_layer.sh` out as CRLF and it would die
with `bad interpreter: /usr/bin/env bash^M`.

## Remaining work

Everything below needs hardware or software this environment cannot provide.
Both have a prepared script or checklist, so neither needs re-derivation.

**Needs real hardware** — a live USB with persistence, dual-boot, or a Steam
Deck. Not Hyper-V or VirtualBox: neither gives a Linux guest a Vulkan device, so
RPCS3 falls back to software and none of these gates mean anything.
Follow `Plans/handoffs/linux-certification-runbook.md`.

- **Real RPCS3 + RAC1, windowed and fullscreen.** Note that "exclusive
  fullscreen" is a Windows concept — `VK_EXT_full_screen_exclusive` does not
  exist on Linux. The equivalent case is the compositor granting *direct
  scanout*, which is what the runbook tests.
- **Present queue family assumption.** The layer assumes family 0. lavapipe
  exposes exactly one queue family, so this is untestable here. Running
  `run_live_tests.sh` on a real GPU closes it.

**Runs in a plain VM** (no GPU needed) via
`tests/run_desktop_integration_tests.sh`:

- **Flatpak verification.** The likeliest real-world failure: a sandboxed
  RPCS3/PCSX2 cannot see `~/.local/share/vulkan` or the Archipelago log dir.
  The script probes both and prints the `flatpak override` it would need.
- **MangoHud coexistence.** Another GLOBAL implicit layer hooking the same
  present call. Partially covered already — the layer is proven to coexist with
  the Khronos validation layer — but not with a second present-hooking overlay.

⚠️ The Flatpak and MangoHud code paths in that script have only been exercised
along their skip branches, since neither tool was installed on the machine it
was written on. Expect to debug the script itself on first real use.

### Live test harness

`tests/run_live_tests.sh` is the Linux counterpart of `run_live_tests.ps1`.
`mock_vk_host.cpp` builds on both platforms — Win32 or xcb — as a binary named
`rpcs3`/`rpcs3.exe` so the process gate activates, and gained `MOCK_READBACK=1`,
which copies the presented swapchain image back to host memory and measures
overlay coverage. That replaces the desktop-screenshot approach with an
in-process measurement, and works headlessly under Xvfb.

Two traps worth remembering, both of which produced confident false passes:

- **Validation never loaded.** Ubuntu 22.04 ships loader 1.3.204, which predates
  `VK_LOADER_LAYERS_ENABLE`, so `VK_INSTANCE_LAYERS` is required; and the
  validation layer reports nowhere unless the app registers a debug messenger or
  `vk_layer_settings.txt` redirects it to stdout. With neither, the error count
  was zero because nothing was checking. The suite now asserts
  `Khronos Validation Layer Active` before trusting a clean result.
- **The pixel control was not a control.** It left the one-time "ready" notice on
  screen, so it measured *more* differing pixels than the event run. It now runs
  with `DISABLE_RANDOVERLAY=1` for a true zero.

## Notes

- Never set `VK_ADD_IMPLICIT_LAYER_PATH` while the manifest is also installed
  in a standard search directory — two discovery routes for one layer crash the
  host. `install_layer.sh --status` warns if it is set.
- `Test-RandOverlay.ps1:191` asserts `runs-on: windows-latest`, but scoped to
  `validate.yml` only, so the new Linux workflow does not trip it.
