# RAC RandOverlay — Vulkan Layer Overlay That Works No Matter What

**Status:** In Progress — layer-coexistence defect found 2026-08-06. Gate (2) is CLOSED (RAC2/RAC3 `ClientComponent` names verified against the installed apworlds; RAC1 corrected). Gate (1) is conditionally unblocked: the layer renders correctly and exits cleanly (~25k frames) when it is the **only** layer above the ICD, but faults on the first present when another layer is below it in the chain — OBS's always-registered `VK_LAYER_OBS_HOOK` gives `0xC0000005`, the Khronos validation layer gives `0xC0000409` with zero validation errors. Root cause is characterised but not isolated; the loader-chain-advance code was checked and is correct. One open confound must be settled first: these runs loaded the layer via `VK_ADD_IMPLICIT_LAYER_PATH` rather than `install_layer.bat`, and implicit-layer **order** determines whether this happens at all. See **Regression — 2026-08-06**.
**Created:** 2026-07-01
**Repo:** RAC1-RandOverlay (`github.com/Club-Tony/RAC1-RandOverlay`) — personal
**Goal:** Finish the `Vulkan-DLL-Version` so Archipelago event text renders *inside* the emulator frame via an implicit Vulkan layer — working in exclusive fullscreen, borderless, and windowed on both RPCS3 (RAC1) and PCSX2 (RAC2/RAC3).

## Plan Relationship And Scope

See [Plans/README.md](README.md) for the canonical plan map and shared manual-test sequence, and the [multi-game overlay roadmap](multi-game-overlay-roadmap.md) for the shared RAC1/RAC2/RAC3 product and configuration contract.

This is a renderer-specific plan. It consumes `RandOverlay.ini`, emulator process mappings, log-source rules, and display settings from the multi-game track. It owns only the implicit Vulkan layer, in-frame ImGui rendering, exclusive-fullscreen behavior, and Vulkan-specific build, install, diagnostics, and safety. Shared message/log UX changes belong in the multi-game track and should be implemented with parity here rather than maintained as a second Vulkan backlog.

All implementation work items in this document were completed on 2026-07-01. As of 2026-08-06 the Launcher-label gate is closed, but a blocking regression in the active present path was found and must be fixed before the real-emulator/fullscreen gate can be attempted — see **Regression — 2026-08-06**.

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

## Regression — 2026-08-06 (validation-layer pass)

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

### The layer terminates the host at first present

Isolation matrix, mock host built AS `rpcs3.exe`, `MOCK_SECONDS=6`, layer supplied via
`VK_ADD_IMPLICIT_LAYER_PATH` (no registry registration needed — worth adopting for future
testing, since it avoids `install_layer.bat` touching HKCU):

| Configuration | Result |
|---|---|
| No layer at all | **PASS** — `exiting after 13119 frames`, clean exit |
| Layer discoverable, `DISABLE_RANDOVERLAY=1` | **PASS** — `exiting after 11608 frames`, clean exit |
| Layer active, validation OFF | **FAIL** — dies at first present, no exit line |
| Layer active, validation ON | **FAIL** — dies at first present, no exit line |

The layer initialises perfectly every run — `layer_debug.log` reaches
`CreateInstance → process gate (rpcs3.exe, RAC1) → log reader → CreateDevice (queueFamily=0)
→ CreateSwapchainKHR (3 images 954x511) → font loaded 43px → ImGui initialized →
Render resources ready (3 framebuffers) → QueuePresentKHR hook LIVE` — and then the
process is gone.

### Root cause: a foreign layer sitting below us in the device chain

Traced by instrumenting `RandOverlay_QueuePresentKHR` (instrumentation since reverted;
`layer.cpp` is unmodified). Findings in order:

1. Fault code is `0xC0000005` (access violation), not a clean exit.
2. The draw branch **is** taken on the very first present — `alpha=0.050, renderReady=1,
   imguiReady=1, haveOverlay=1, scCount=1, match=1`. The one-time "Archipelago Overlay
   ready" startup notice is mid-fade-in on frame 1, so frame 1 goes through the full
   record/submit path. (The pass-through branch is *not* implicated.)
3. Not a null dispatch entry: the queue dispatch key matches the device key and
   `QueuePresentKHR`/`QueueSubmit` both resolve to valid pointers.
4. Not a failed ImGui function load: instrumenting `ImguiLoader` showed **zero** null
   resolutions — the GDPA→GIPA fallback works.
5. Bisecting the draw block: `ResetCommandBuffer` OK → `BeginCommandBuffer` OK →
   **fault inside `CmdBeginRenderPass`**.
6. Resolving each entry point to its owning module is the answer:

   | Entry point | Resolves into |
   |---|---|
   | `BeginCommandBuffer` | `nvoglv64.dll` (NVIDIA ICD) |
   | `QueueSubmit` | `nvoglv64.dll` (NVIDIA ICD) |
   | `CmdBeginRenderPass` | **`C:\ProgramData\obs-studio-hook\graphics-hook64.dll`** |
   | `QueuePresentKHR` | **`C:\ProgramData\obs-studio-hook\graphics-hook64.dll`** |

OBS Studio registers `VK_LAYER_OBS_HOOK` as a **GLOBAL implicit layer**
(`C:\ProgramData\obs-studio-hook\obs-vulkan64.json`), so it loads into every Vulkan
application whether or not OBS is running — OBS was **not** running for any of these runs.
Recording our own overlay command buffer through OBS's hooked `vkCmdBeginRenderPass`
faults.

Suppressing just that layer via its own documented kill-switch makes everything work:

| Configuration | Result |
|---|---|
| RandOverlay + OBS layer | **FAIL** — `0xC0000005` |
| RandOverlay, `DISABLE_VULKAN_OBS_CAPTURE=1` | **PASS** — exit `0x0`, 24906-25662 frames, overlay renders |
| RandOverlay + Khronos validation, OBS off | **FAIL** — `0xC0000409` (`__fastfail`), **0 validation errors** |

The third row is the important one: validation alone breaks it too, with a *different*
fault code and without validation itself reporting a single error. So this is not
specifically an OBS bug — the layer misbehaves when **any** additional layer sits below it
in the device chain, and is only reliable when it is the sole layer above the ICD.

The obvious suspect — failing to advance the loader chain link — was checked and is
**not** the cause: `layer.cpp:393` and `layer.cpp:444` both correctly do
`layerInfo->u.pLayerInfo = layerInfo->u.pLayerInfo->pNext` before calling down. The defect
is elsewhere in how the layer records and submits its own work through entry points that
another layer has hooked. Not yet isolated.

Validation's only diagnostics are 8 instances of `WARNING-vkGetDeviceProcAddr-device`
(instance-level entry points fetched through `vkGetDeviceProcAddr`, from `ImguiLoader`
trying GDPA first). Benign — the GIPA fallback covers them — but worth tidying by asking
for instance-level functions through GIPA directly.

### Open confound — layer ORDER, not necessarily a regression

These runs loaded the layer with `VK_ADD_IMPLICIT_LAYER_PATH`, whereas the successful
2026-07-01 session used `install_layer.bat` (HKCU registry registration). Implicit-layer
**ordering** decides which layer sits below which, and therefore whether our down-chain
calls land in the ICD or in OBS's hook. OBS's manifest (dated 2024-04-11) was already
registered on 2026-07-01, yet that session ran 65735 frames cleanly — so the difference is
plausibly discovery order, not a code change.

**Do not record this as a confirmed regression until that is settled.** The deciding test
is to register the layer the documented way (`install_layer.bat`, HKCU) and re-run with OBS
present; if it passes, the conflict is an artefact of the env-var loading path and the real
constraint is "RandOverlay must be ordered below other capture layers". That test mutates
HKCU, so it needs an explicit go-ahead, and `uninstall_layer.bat` reverses it.

### Reproducer

```
build\ (mock host built AS rpcs3.exe from tests\mock_vk_host.cpp)
set VK_ADD_IMPLICIT_LAYER_PATH=<repo>\Vulkan-DLL-Version
set RANDOVERLAY_INI=<a test ini whose LogDir points at a scratch log dir>
set RANDOVERLAY_NO_PROMPT=1
set MOCK_SECONDS=6
rpcs3.exe > mock_stdout.log 2>&1
```

PASS looks like `[mock] exiting after N frames`; FAIL is the absence of that line. Launch
it with PowerShell `Start-Process -PassThru … ; $p.WaitForExit()` — a bare shell loses the
handle and reaps the process early, which masks the difference.

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
1. `build.bat` → `RandOverlay_layer.dll` builds clean; `install_layer.bat` registers it.
2. RPCS3 + RAC1, **exclusive fullscreen**. Trigger an Archipelago event (or append a matching `[FileLog at …]:` line to the newest `C:\ProgramData\Archipelago\logs\Launcher_*.txt`). Confirm text renders inside the frame in fullscreen.
3. Repeat borderless + windowed. Repeat PCSX2 + RAC2/RAC3.
4. `build/layer_debug.log` shows the full chain: `CreateInstance → CreateDevice → CreateSwapchainKHR → Swapchain: N images … → Message: …`.
5. Gating: a non-emulator Vulkan app (e.g. `vkcube`) is unaffected. `DISABLE_RANDOVERLAY=1` disables cleanly.
6. Regression: AHK + PS+WPF runtimes and `Test-RandOverlay.ps1` still pass.

> After implementation the live emulator/fullscreen verification is manual (needs RPCS3/PCSX2 + a running randomizer), so status moves to **Awaiting Manual Action**, then **Completed** once the user confirms text renders in fullscreen.
