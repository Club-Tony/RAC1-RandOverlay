# RAC RandOverlay — Vulkan Layer Overlay That Works No Matter What

**Status:** Awaiting Manual Action — 2026-08-06 pass: gate (2) CLOSED (RAC2/RAC3 `ClientComponent` names verified against the installed apworlds; RAC1 corrected to its own apworld client), build fixed (`ar` was not pinned to the x64 toolchain), 34/34 unit tests, and the layer verified end-to-end on the mock host **with OBS Studio running and its `VK_LAYER_OBS_HOOK` active** — 27704 frames, clean exit, both Archipelago events rendered. Gate (1), the real RPCS3/PCSX2 exclusive-fullscreen run, is unblocked and remains the only gate to Completed. One non-blocking defect is open: the layer is incompatible with the Khronos validation layer (`0xC0000409`, zero validation errors), so the optional validation audit of the three residual notes could not be performed.
**Created:** 2026-07-01
**Repo:** RAC1-RandOverlay (`github.com/Club-Tony/RAC1-RandOverlay`) — personal
**Goal:** Finish the `Vulkan-DLL-Version` so Archipelago event text renders *inside* the emulator frame via an implicit Vulkan layer — working in exclusive fullscreen, borderless, and windowed on both RPCS3 (RAC1) and PCSX2 (RAC2/RAC3).

## Plan Relationship And Scope

See [Plans/README.md](README.md) for the canonical plan map and shared manual-test sequence, and the [multi-game overlay roadmap](multi-game-overlay-roadmap.md) for the shared RAC1/RAC2/RAC3 product and configuration contract.

This is a renderer-specific plan. It consumes `RandOverlay.ini`, emulator process mappings, log-source rules, and display settings from the multi-game track. It owns only the implicit Vulkan layer, in-frame ImGui rendering, exclusive-fullscreen behavior, and Vulkan-specific build, install, diagnostics, and safety. Shared message/log UX changes belong in the multi-game track and should be implemented with parity here rather than maintained as a second Vulkan backlog.

All implementation work items in this document were completed on 2026-07-01. As of 2026-08-06 the Launcher-label gate is closed and the layer is verified to coexist with the OBS capture hook; the real-emulator/fullscreen run is the only remaining gate — see **Verification Pass — 2026-08-06**.

## Historical Starting Point — Superseded By The Validation Log Below

The overlay shows Archipelago randomizer events over the game. The two shipping runtimes — `RandOverlay.ahk` and `PS+WPF-Version` — draw a translucent click-through **window** on top of the emulator. A top-most window **cannot draw over an exclusive-fullscreen Vulkan swapchain**, so those versions only work in borderless/windowed. The `Vulkan-DLL-Version` exists to fix exactly that: draw the text into the game's own frame at present time, so it works no matter the display mode.

At plan creation, two Vulkan code paths had been started but **neither rendered anything real**:

- **Implicit layer** (`src/layer.cpp`, `RandOverlay_layer.json`) — the correct in-dispatch-chain approach. The fresh `build/layer_debug.log` (2026-07-01 00:21) shows it loads and intercepts `vkCreateInstance` + `vkCreateDevice`, then **stops** — no `vkCreateSwapchainKHR`, no present. So `SetupRender` never runs, `g_renderReady` stays false, and present just passes through. Even when it does draw, it only draws a placeholder colored bar via `vkCmdClearAttachments` — no text.
- **MinHook injected DLL** (`src/overlay.cpp`, `src/injector.cpp`) — `build/overlay_debug.log` shows the DLL injects and hooks the loader-exported `vulkan-1.dll!vkQueuePresentKHR`, but the `HookedPresent` callback **never fires** ("First present!" never logged). RPCS3 was already running and had resolved its device-level present pointer via `vkGetDeviceProcAddr` *before* injection, so it never calls the loader export the hook sits on. Late injection can't catch already-resolved device calls. It also casts `(VkDevice)queue` (wrong) and has an empty draw pass (`// TODO: ImGui`).

`deps/imgui` is fully vendored (`imgui_impl_vulkan` + `imgui_impl_win32` + built-in stb_truetype font), so real text rendering is ready to wire — it just never was. Vulkan SDK `1.4.341.1` is installed. `build.bat` builds the injector + `overlay.dll` but has **no target that builds the layer DLL** (it was compiled manually).

**Decisions (from /ask):**
- **Mechanism:** implicit layer is the authoritative "works no matter what" path; keep the injected DLL as an optional no-registry fallback (do not invest in fixing its hook this milestone).
- **Scope:** RPCS3 (RAC1) **and** PCSX2 (RAC2/RAC3) — both are Vulkan-capable.

## Environment notes (discovered during implementation)
- x64 toolchain: **`C:\mingw64\bin\g++` (GCC 14.2.0, x86_64-w64-mingw32)** is the correct compiler. `C:\MinGW\bin` is 32-bit MinGW.org 6.3.0 and must NOT be used — a 32-bit DLL cannot load into RPCS3. `build.bat` now guards on `g++ -dumpmachine`.
- imgui vendored version (~1.92, 2025-06): fonts upload automatically (`ImGuiBackendFlags_RendererHasTextures`, no manual `CreateFontsTexture`); descriptor pool can be backend-created via `InitInfo.DescriptorPoolSize>0`; render pass goes in `PipelineInfoMain.RenderPass`; `ImGui_ImplVulkan_LoadFunctions()` is required under `VK_NO_PROTOTYPES`. Overlay is driven with **no platform backend** (set `io.DisplaySize`/`DeltaTime` manually) since it takes no input.

## Validation Log — 2026-07-01 (mock Vulkan host)

Built a mock Vulkan host (`tests/mock_vk_host.cpp`, compiled AS `rpcs3.exe`) that opens a
window and runs a real present loop, so the implicit layer can be exercised end-to-end on
the actual GPU (RTX 4070 SUPER) without RPCS3. Also added headless unit tests
(`tests/test_units.cpp`, 20/20 pass) for the ini reader, process gate, and log parser.

- **Root-cause bug found + fixed:** the layer loaded and hooked `vkCreateSwapchainKHR` but
  **never `vkQueuePresentKHR`** — its present hook was never wired, so nothing ever drew.
  Cause: `RandOverlay_GetDeviceProcAddr` did not return **itself** for `"vkGetDeviceProcAddr"`,
  so when the loader resolved the chain through us to build the device dispatch table it got
  the terminator's GDPA and built `QueuePresentKHR` bypassing our layer. Fix: return our own
  `Get{Device,Instance}ProcAddr` (canonical layer requirement). Diagnostic proof: after the
  fix the loader queries `vkQueuePresentKHR`, `QueuePresentKHR hook LIVE` fires, the event is
  picked up, and the overlay draws.
- **Visual confirmation:** screenshot showed the ImGui panel **"Ratchet found their
  Hydrodisplacer"** rendered inside the frame in the configured `#80A0D0` on `#1E1E1E` at
  `VerticalPercent=0.17`. A clean 30s run drew 65735 frames with the overlay active — no
  crash, no hang.
- **Still manual:** real RPCS3/PCSX2 in exclusive fullscreen (the mock is windowed) and a
  Vulkan-validation-layer pass to confirm the three residual notes (queue-family assumption,
  fence-less cmd-buffer reuse, OUT_OF_DATE semaphore). Confidence is now high.

### AHK/PS display-parity pass (same day, later)

Aligned the layer's message display with the AHK and PS+WPF runtimes (compared against
`RandOverlay.ahk` `ArchShowMessage`/`ArchPollLog` and `RandOverlay.ps1`):
- **Fade lifecycle** — fade in `FadeInMs` (300) → hold `DisplayMs` → fade out `FadeOutMs`
  (500); alpha multiplies both panel bg and text (AHK whole-window fade analog).
- **Poll cadence** — log polled every `PollMs` (1500) instead of every present.
- **Log selection** — newest `*.txt` excluding `Generate_`/`Server_` (was `Launcher_*.txt`
  only — would have missed game-specific client logs).
- **Geometry** — top edge at `height×VerticalPercent` (was center-pivot), AHK 12,8 margins,
  bg opacity 0.80 (WPF value), width clamped to 92% of frame with wrap (fixes the clipping
  found in the example run; AHK/WPF are top-level windows so they never hit a frame edge).
- **Startup notice** — one-time "Archipelago Overlay ready - waiting for events" like both runtimes.
- New ini keys read: `PollMs`, `FadeInMs`, `FadeOutMs`. Unit tests extended to 25 (all pass);
  wrap + top-edge visually verified via the mock host; RTSS/RivaTuner hooked the same mock
  present chain concurrently with no conflict (good layer-coexistence signal).

### Launch prompt + R&C font + real-Archipelago E2E (same day, evening)

- **R&C font**: new `src/font_resolver.h` maps FontFamily→TTF via the Windows font registry
  (HKCU then HKLM); layer now loads `HandelGothic BT` (per-user `HandelGo.ttf`) at
  `WpfFontSize`, falling back Bahnschrift → ImGui default. Visually confirmed in-frame.
- **Launch prompt**: new `src/arch_client_check.h` — when the overlay activates and no
  `Archipelago*` process exists, a non-blocking three-way prompt (background thread) offers
  Yes = launch the active preset's client (`ArchipelagoLauncher.exe "<ClientComponent>"`),
  No = open the Launcher to pick any installed client, Cancel = nothing.
  `RANDOVERLAY_NO_PROMPT=1` suppresses. New per-preset ini key `ClientComponent`
  (RAC1 `Text Client`, RAC2 `Ratchet & Clank 2 Client`, RAC3 `Ratchet and Clank 3 Client`) —
  chosen because apworld client components can't be reliably enumerated from a DLL; the
  Launcher UI is the authoritative picker for the "which client?" case.
- **Real-Archipelago E2E (mock emulator + real client)**: with the reader pointed at the real
  `C:\ProgramData\Archipelago\logs`, the user launched the real Text Client mid-session →
  layer logged `Log switched: ...Launcher_2026_07_01_20_24_08.txt` (live client-restart
  resilience) → a labeled test line appended to that real log rendered in-frame in Handel
  Gothic. Test line removed from the real log afterwards. Unit tests now 34/34
  (`tests/run_tests.bat`).
- Remaining gate unchanged: real RPCS3/PCSX2 exclusive-fullscreen run + validation layer.
  Also verify the RAC2/RAC3 `ClientComponent` names match the Launcher UI exactly on Yes.

## Verification Pass — 2026-08-06 (build, tests, OBS coexistence, validation)

Ran the deterministic half of the Verification section on [dev-machine]. Toolchain intact:
`C:\mingw64\bin\g++` (GCC 14.2.0, x86_64-w64-mingw32), Vulkan SDK `1.4.341.1` including
`VkLayer_khronos_validation.dll`.

### Build fix — `ar` was not pinned to the x64 toolchain

`build.bat` pinned `g++`/`gcc` to `C:\mingw64` and guarded on `-dumpmachine`, but invoked
a bare `ar`. On this device that resolves to `C:\MinGW\bin\ar.exe` — the **32-bit
MinGW.org binutils 2.28** that the Environment notes explicitly warn against — producing
`libminhook.a: error adding symbols: archive has no index` and failing step [3/4]. The
PRIMARY layer target [1/4] was unaffected (it does not archive), which is why this stayed
hidden. Fixed by adding an `AR` variable pinned the same way as `GCC`/`GCC_C`. Full build
is now clean: layer DLL, MinHook, `overlay.dll`, `injector.exe`.

- Unit tests: **34/34 pass** (`tests\run_tests.bat`), including the font resolver
  (`HandelGothic BT` → `…\Fonts\HandelGo.ttf`) and log-selection parity cases.

### What happened: a self-inflicted test-harness fault, not a product defect

The first pass loaded the layer with `VK_ADD_IMPLICIT_LAYER_PATH` and saw the mock host die
at the first present with `0xC0000005`. That was caused by the test method itself.

The layer was **already registered** in `HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers`, as
`%USERPROFILE%\Documents\GitHub\Repositories\...\RandOverlay_layer.json`. That path is not
stale — `Documents\GitHub` is a **junction** to `Documents\.workspace`, so it resolves to the
same manifest. Adding `VK_ADD_IMPLICIT_LAYER_PATH` on top gave the loader a second discovery
route for the same layer, and the resulting chain faulted on the first present.

**Caveat for future testing: never set `VK_ADD_IMPLICIT_LAYER_PATH` for this layer while it
is registry-registered.** Use one discovery route or the other. The earlier note in this plan
suggesting the env var as a way to avoid touching HKCU was wrong and is retracted.

### Verified working with OBS — the real-world configuration

Re-run in the documented configuration (HKCU registration only, no
`VK_ADD_IMPLICIT_LAYER_PATH`), with **OBS Studio 32.2.1 running** and its always-registered
`VK_LAYER_OBS_HOOK` implicit layer active in the chain:

| Configuration | Result |
|---|---|
| Registry-only, OBS running, no validation | **PASS** — exit `0x0`, 15049 frames |
| Registry-only, OBS running, + Archipelago events | **PASS** — exit `0x0`, 27704 frames, both events rendered |
| Registry-only, OBS running, + Khronos validation | **FAIL** — `0xC0000409`, 0 validation errors |
| `VK_ADD_IMPLICIT_LAYER_PATH` + registry (double discovery) | **FAIL** — `0xC0000005` |

The event run is the meaningful one: with OBS live, the layer picked up and rendered both
appended Archipelago lines —

```
Message: Ratchet found their Hydrodisplacer
Message: Clank found their Thruster-Pack
```

So the layer coexists with the OBS capture hook, which matters because the OBS profile on
this device is built around emulator capture (scenes `Emulator cap`, `Emulator cap with
overlay`). No workaround and nothing to disable.

### Genuine remaining defect: incompatible with the Khronos validation layer

One real finding survives. With the layer loaded the documented way, enabling
`VK_LAYER_KHRONOS_validation` kills the process with `0xC0000409`
(`STATUS_STACK_BUFFER_OVERRUN` / `__fastfail`) while validation itself reports **zero
errors**. Reproduced both with and without the OBS layer present, so validation is the
trigger.

This blocks only the optional "run once with the validation layer on" sub-gate. It has no
effect on production use, since nobody ships with validation enabled — but it does mean the
three residual notes (queue-family assumption, fence-less cmd-buffer reuse, `OUT_OF_DATE`
semaphore) remain **unaudited** rather than cleared. Not yet isolated. The loader chain-link
advance was checked and is correct (`layer.cpp:393`, `layer.cpp:444`), so the fault is
elsewhere.

Validation's only other output is 8 instances of `WARNING-vkGetDeviceProcAddr-device`
(instance-level entry points fetched through `vkGetDeviceProcAddr`, from `ImguiLoader` trying
GDPA before falling back to GIPA). Benign, but worth tidying by requesting instance-level
functions through GIPA directly.

### Reproducer

Build the mock host AS `rpcs3.exe` from `tests\mock_vk_host.cpp`, then, with the layer
registered via `install_layer.bat` and **no** `VK_ADD_IMPLICIT_LAYER_PATH` set:

```
set RANDOVERLAY_INI=<test ini whose LogDir points at a scratch log dir>
set RANDOVERLAY_NO_PROMPT=1
set MOCK_SECONDS=20
rpcs3.exe > mock_stdout.log 2>&1
```

PASS looks like `[mock] exiting after N frames` plus `Message:` lines in
`build\layer_debug.log`; FAIL is the absence of the exit line. Launch via PowerShell
`[System.Diagnostics.Process]::Start(...)` + `WaitForExit()` and read `$proc.ExitCode` — a
bare shell loses the handle, reaps the process early, and reports a misleading `127`. Append
event lines to the tailed log *while the process runs*; the reader seeds its line count at
startup, so pre-existing lines are skipped by design.

### Gate (2) — CLOSED

`ClientComponent` values checked directly against the component registrations in the
installed apworlds (`C:\ProgramData\Archipelago\custom_worlds`), which is authoritative
for what the Launcher UI lists:

| Preset | apworld registers | `RandOverlay.ini` | Result |
|---|---|---|---|
| RAC2 | `"Ratchet & Clank 2 Client"` | `Ratchet & Clank 2 Client` | match |
| RAC3 | `f"{GAME_TITLE_FULL} Client"` where `GAME_TITLE_FULL = "Ratchet and Clank 3"` | `Ratchet and Clank 3 Client` | match |
| RAC1 | `"Ratchet & Clank Client"` | was `Text Client` | **corrected** |

RAC1 was outside the original gate but `RAC1.apworld` ships its own client component, so
the preset pointed at the generic text client while RAC2/RAC3 launched their game-specific
ones. Updated to `Ratchet & Clank Client` for consistency across the three presets.

## Completed Implementation Record (original work-item order)

The six items below are retained to explain the implemented architecture and review boundaries. They are complete in `dc86da4`; they are not the next-action queue. Remaining actions are the manual checks under **Verification**.

### 1. Diagnose why the layer stops at `vkCreateDevice`
Resolve this before trusting rendering. Add verbose logging to `RandOverlay_GetInstanceProcAddr`/`GetDeviceProcAddr` (log every `pName`) and at the top of `RandOverlay_CreateSwapchainKHR`/`RandOverlay_QueuePresentKHR`. Rebuild and run RPCS3 **with a game booted to actual rendering** (the swapchain isn't created until frames present — the truncated log is most likely a session that never reached gameplay). If still not routed, verify `InitDeviceDispatch` resolves every function with no nulls (log any null) and that both proc-addr entry points return the hooks.

### 2. Robust swapchain + present (`src/layer.cpp`, `src/layer_dispatch.h`)
- Retrieve a real **graphics queue** at device-creation via `vkGetDeviceQueue`; use its family for the command pool.
- Handle **swapchain recreation** (resolution/fullscreen⇄windowed/vsync all re-call `vkCreateSwapchainKHR`): `DeviceWaitIdle` → cleanup → rebuild, honoring `oldSwapchain`.
- Never break the game: on any setup failure, log and pass through (`g_renderReady=false`). Handle `swapchainCount>1` (match our swapchain) and correct `pImageIndices`.
- Keep the present-sync pattern (wait on app semaphores, signal ours, present waits on ours), verified against imgui's submission.

### 3. Real text via imgui (replace placeholder bar / empty pass)
- Init `imgui_impl_vulkan` against the overlay render pass (LOAD_OP_LOAD); backend-created descriptor pool; MSAA=1.
- Custom loader routes imgui's Vulkan calls **down the chain** (next-layer GetDeviceProcAddr → GetInstanceProcAddr), never the `vulkan-1.dll` exports. Compile imgui backend with `-DIMGUI_IMPL_VULKAN_NO_PROTOTYPES`.
- Per present with an active message: manual imgui frame → translucent display-only text panel → `RenderDrawData` into our cmd buffer → submit before present.

### 4. Style + message parity with existing runtimes
- Read the shared `RandOverlay.ini` (active preset RAC1/2/3): `OverlayColor`, `BackgroundColor`, `VerticalPercent`, font size, `DisplayMs`. Keeps all three runtimes visually consistent.
- `src/log_reader.h` already tails `C:\ProgramData\Archipelago\logs\Launcher_*.txt`; align event set / text cleanup with AHK/PS. Message stack + fade optional.

### 5. Process gating (makes a GLOBAL implicit layer safe)
- In `RandOverlay_CreateInstance`, read the host image name; if not `rpcs3.exe`/`pcsx2-qt.exe`/`pcsx2.exe`, self-disable and pass through. Keep the `DISABLE_RANDOVERLAY=1` kill-switch.

### 6. Build + install workflow
- Add a **layer build target** to `build.bat` (was absent): `layer.cpp` + imgui core + `imgui_impl_vulkan.cpp` → `build/RandOverlay_layer.dll` (x64 g++, Vulkan SDK, `-DVK_NO_PROTOTYPES -DIMGUI_IMPL_VULKAN_NO_PROTOTYPES`) + the x86_64 arch guard.
- Confirm `RandOverlay_layer.json` `library_path` matches output; `install_layer.bat` (HKCU implicit layer) registers it; `uninstall_layer.bat` reverses it.
- Injector fallback: keep `overlay.dll` building/documented. A `vulkan-1.dll` proxy shim fix for its hook is **out of scope** this milestone.

## Critical Files
- `Vulkan-DLL-Version/src/layer.cpp`, `src/layer_dispatch.h` — authoritative path.
- `Vulkan-DLL-Version/src/config.h`, `src/process_gate.h` — new shared ini + gating.
- `Vulkan-DLL-Version/src/log_reader.h` — message source.
- `Vulkan-DLL-Version/RandOverlay_layer.json`, `install_layer.bat`, `uninstall_layer.bat` — manifest + registration.
- `Vulkan-DLL-Version/build.bat` — layer+imgui target + arch guard.
- `Vulkan-DLL-Version/deps/imgui/**` — vendored renderer.
- `RandOverlay.ini` — shared style/preset config (repo root).
- `Vulkan-DLL-Version/src/overlay.cpp`, `src/injector.cpp` — fallback (kept, not the focus).

## Verification (end-to-end)

Steps 1, 4, 5 and the build/test half of this list were completed on 2026-08-06 (see
**Verification Pass — 2026-08-06**). Steps 2 and 3 are the remaining manual gate.

1. ~~`build.bat` → `RandOverlay_layer.dll` builds clean; `install_layer.bat` registers it.~~
   **Done.** Build is clean including the fallback. The layer is **already registered** in
   `HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers` — re-running `install_layer.bat` is
   harmless but unnecessary. **Do not set `VK_ADD_IMPLICIT_LAYER_PATH`**; a second
   discovery route for the same layer crashes the host (`0xC0000005`).
2. **REMAINING GATE.** RPCS3 + RAC1, **exclusive fullscreen**. Trigger an Archipelago event (or append a matching `[FileLog at …]:` line to the newest `C:\ProgramData\Archipelago\logs\Launcher_*.txt`). Confirm text renders inside the frame in fullscreen.
3. **REMAINING GATE.** Repeat borderless + windowed. Repeat PCSX2 + RAC2/RAC3.
4. ~~`build/layer_debug.log` shows the full chain~~ — **confirmed** on the mock host:
   `CreateInstance → CreateDevice → CreateSwapchainKHR → Swapchain: 3 images → Font loaded →
   ImGui initialized → Render resources ready → QueuePresentKHR hook LIVE → Message: …`,
   with OBS running.
5. ~~Gating~~ — **confirmed**: `DISABLE_RANDOVERLAY=1` disables cleanly (host runs to
   completion, layer inert). A non-emulator Vulkan app remains untested but the process
   gate is unit-covered.
6. Regression: AHK + PS+WPF runtimes and `Test-RandOverlay.ps1` still pass. *(Not re-run on
   2026-08-06 — no shared code was touched; only `build.bat`, `RandOverlay.ini`'s RAC1
   `ClientComponent`, and plan docs changed. The ini change does affect the shared preset
   contract, so this is worth a confirming run.)*
7. ~~Ideally one run with the Vulkan validation layer enabled.~~ **BLOCKED** — the layer is
   incompatible with `VK_LAYER_KHRONOS_validation` (`0xC0000409`, zero validation errors).
   Tracked in [handoffs/2026-08-06-vulkan-validation-layer-incompatibility.md](handoffs/2026-08-06-vulkan-validation-layer-incompatibility.md).
   Consequence: the three residual notes (queue-family assumption, fence-less cmd-buffer
   reuse, `OUT_OF_DATE` semaphore) remain **unaudited**, not cleared.

> The live emulator/fullscreen verification is manual (needs RPCS3/PCSX2 + a running randomizer), so status stays **Awaiting Manual Action** until steps 2-3 pass, then **Completed**. The validation-layer defect in step 7 does **not** block Completed — it is non-blocking follow-on work with its own handoff.
