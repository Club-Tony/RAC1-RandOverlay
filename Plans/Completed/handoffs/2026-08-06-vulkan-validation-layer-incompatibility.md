# Handoff: isolate the RandOverlay Vulkan layer's incompatibility with the Khronos validation layer

**Status:** Planned — open defect, not blocking production use
**Created:** 2026-08-06
**Type:** Handoff
**Parent plan:** [vulkan-overlay-works-no-matter-what.md](../vulkan-overlay-works-no-matter-what.md)

## Mission

The RandOverlay Vulkan implicit layer works correctly in production, but the host process
dies with `0xC0000409` whenever the Khronos validation layer is also enabled — while
validation itself reports **zero errors**. Find and fix the fault. Done means: the mock
host runs to completion with `VK_LAYER_KHRONOS_validation` enabled, and the validation
output is then used to audit the three long-standing residual notes (queue-family
assumption, fence-less command-buffer reuse, `OUT_OF_DATE` semaphore handling), which
remain unaudited rather than cleared.

This is a debuggability defect, not a user-facing one — nobody ships with validation
enabled. Do not treat it as urgent, and do not destabilise the working production path
to fix it.

## Environment

- OS/shell: Windows 11 Pro, PowerShell primary (a POSIX shell is also available; note the
  launch quirk under *Gotchas* — it matters).
- Repo: `%USERPROFILE%\Documents\.workspace\Repositories\RAC1-RandOverlay`
  - Note: `%USERPROFILE%\Documents\GitHub` is a **junction** to
    `%USERPROFILE%\Documents\.workspace`, so both paths address the same files.
- Branch: `rac123-support` (not the default branch).
- Vulkan project root: `...\RAC1-RandOverlay\Vulkan-DLL-Version`
- Toolchain: `C:\mingw64\bin\g++` (GCC 14.2.0, x86_64-w64-mingw32). **Never** use
  `C:\MinGW\bin` — that is 32-bit MinGW.org 6.3.0 and cannot produce a loadable DLL.
- Vulkan SDK `1.4.341.1` at `C:\VulkanSDK\1.4.341.1`, including
  `Bin\VkLayer_khronos_validation.dll`.
- GPU: NVIDIA RTX 4070 SUPER; ICD is `nvoglv64.dll`.

## State of play

### Completed (2026-08-06)

- `Vulkan-DLL-Version\build.bat` — pinned `AR` to the x64 toolchain. A bare `ar` resolved
  to the 32-bit MinGW.org binutils and broke the fallback link with
  `libminhook.a: archive has no index`. Full build is clean.
- `RandOverlay.ini` — RAC1's `ClientComponent` corrected from `Text Client` to
  `Ratchet & Clank Client` (RAC1.apworld registers its own client). RAC2/RAC3 names were
  verified against the installed apworlds and already matched.
- Unit tests: 34/34 via `Vulkan-DLL-Version\tests\run_tests.bat`.
- Production path verified on the mock host with OBS Studio 32.2.1 running and its
  `VK_LAYER_OBS_HOOK` implicit layer active: 27704 frames, clean exit, both injected
  Archipelago events rendered.

### The open defect

With the layer loaded the documented way and `VK_LAYER_KHRONOS_validation` enabled, the
process terminates with `0xC0000409` (`STATUS_STACK_BUFFER_OVERRUN` / `__fastfail`) shortly
after `QueuePresentKHR hook LIVE` is logged. Validation reports **0 errors** before the
fault. Reproduced both with and without the OBS layer present, so validation is the
trigger, not OBS.

### Decisions made — do not re-litigate

- The layer is only reachable through its dispatch chain; the production configuration is
  HKCU registry registration via `install_layer.bat`. Keep it that way.
- Production correctness takes priority over validation compatibility. If a fix would
  regress the OBS-coexistence result above, it is the wrong fix.
- The `0xC0000005` crash recorded earlier in the parent plan's history was a test-harness
  artefact, not a product defect. It is resolved. Do not chase it.

### Approaches already tried and ruled out

- **Loader chain-link advance not being performed.** Checked — it is correct.
  `Vulkan-DLL-Version\src\layer.cpp` lines 393 and 444 both do
  `layerInfo->u.pLayerInfo = layerInfo->u.pLayerInfo->pNext` before calling down.
- **Null entries in the device dispatch table.** Instrumented: the queue dispatch key
  matches the device key, and `QueuePresentKHR` / `QueueSubmit` both resolve to valid
  pointers.
- **ImGui failing to load a Vulkan function.** Instrumented `ImguiLoader`: **zero** null
  resolutions. Its GDPA-then-GIPA fallback works.
- **The fault being in the pass-through branch.** It is not. The one-time "Archipelago
  Overlay ready" startup notice is mid-fade-in on frame 1 (`alpha≈0.05`), so the very
  first present takes the full record/submit branch.
- **Blaming OBS.** The validation fault reproduces with OBS's layer disabled via
  `DISABLE_VULKAN_OBS_CAPTURE=1`.

## Pending work — do these

1. **Reproduce the fault.** Build, then run the mock host with validation enabled per
   *Verification* below. Acceptance: you observe exit code `0xC0000409` and confirm
   `build\layer_debug.log` ends at or shortly after `QueuePresentKHR hook LIVE`.
2. **Locate the faulting call.** Bisect the draw branch in `RandOverlay_QueuePresentKHR`
   (`Vulkan-DLL-Version\src\layer.cpp`, the block guarded by `haveOverlay`) with logging
   between each step, exactly as was done for the earlier crash: `ResetCommandBuffer` →
   `BeginCommandBuffer` → `CmdBeginRenderPass` → `DrawOverlay` → `CmdEndRenderPass` →
   `EndCommandBuffer` → `QueueSubmit` → `QueuePresentKHR`. Acceptance: a named call site
   that is the last thing to execute.
   - `0xC0000409` is a stack-corruption / security-cookie failure, so also consider
     struct-size or calling-convention mismatches between what the layer passes and what
     validation expects — a `VkSubmitInfo` / `VkPresentInfoKHR` / `VkRenderPassBeginInfo`
     built with a stale or partially-initialised layout is a strong candidate. Note
     `waitStages` in the submit path is sized from `pPresentInfo->waitSemaphoreCount`.
3. **Fix it without regressing production.** Acceptance: validation run completes with
   `[mock] exiting after N frames`, 0 validation errors; **and** the OBS-coexistence run
   still passes with events rendered.
4. **Audit the three residual notes** using the now-working validation output: queue-family
   assumption, fence-less command-buffer reuse, and `OUT_OF_DATE` semaphore handling.
   Acceptance: each is either confirmed clean or filed as a distinct issue.
5. **Remove all temporary instrumentation** and confirm `git status` shows only intended
   changes. Update the parent plan with the outcome.

## Key context and gotchas

- **Never set `VK_ADD_IMPLICIT_LAYER_PATH` for this layer.** It is already registered in
  `HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers`. Setting the env var too gives the loader a
  second discovery route for the same layer and produces a *different* crash
  (`0xC0000005`). Confusing the two wastes hours. Use the registry registration only.
- **Launch the mock host from .NET, not from a shell.** A POSIX shell loses the handle on
  the Windows GUI process, reaps it early, and reports a misleading exit code `127`, which
  looks like a crash but is not. Use
  `[System.Diagnostics.Process]::Start($psi)` + `$proc.WaitForExit()` + `$proc.ExitCode`.
- **The mock host must be named `rpcs3.exe`** or the layer's process gate self-disables.
  Build it from `Vulkan-DLL-Version\tests\mock_vk_host.cpp`.
- **`MOCK_SECONDS`** controls the mock's runtime (default 30). **`RANDOVERLAY_NO_PROMPT=1`**
  suppresses the Archipelago launch dialog — always set it in automated runs.
- **The log reader seeds its line count at startup**, so pre-existing lines in the tailed
  log are deliberately skipped. To exercise the message path, append event lines *while the
  process is running*. Lines must match `[FileLog at ...]: <text>` and contain one of the
  interest keywords (e.g. `found their`).
- **`Vulkan-DLL-Version\build\` is gitignored**, so build artefacts and the mock host do not
  pollute the repo.
- Point `RANDOVERLAY_INI` at a scratch copy of `RandOverlay.ini` whose `LogDir` is a
  throwaway directory, so tests never write to `C:\ProgramData\Archipelago\logs`.
- Validation emits 8 benign `WARNING-vkGetDeviceProcAddr-device` warnings (instance-level
  entry points fetched through `vkGetDeviceProcAddr` by `ImguiLoader` before it falls back
  to GIPA). These are not the bug, but tidying them by requesting instance-level functions
  through GIPA directly is a reasonable side fix.
- The repo rejects commits containing AI-attribution trailers; omit them.

## Verification

Build:

```
cd %USERPROFILE%\Documents\.workspace\Repositories\RAC1-RandOverlay\Vulkan-DLL-Version
build.bat
tests\run_tests.bat
```

Expect `RandOverlay_layer.dll OK` through `injector.exe OK`, and `34 passed, 0 failed`.

Build the mock host as `rpcs3.exe`:

```
C:\mingw64\bin\g++ -O2 -std=c++17 -DWIN32_LEAN_AND_MEAN -I C:\VulkanSDK\1.4.341.1\Include ^
  tests\mock_vk_host.cpp -o build\rpcs3.exe ^
  -L C:\VulkanSDK\1.4.341.1\Lib -lvulkan-1 -lkernel32 -luser32 -lgdi32 ^
  -static -static-libgcc -static-libstdc++
```

Failing case (the defect) — PowerShell, with `VK_ADD_IMPLICIT_LAYER_PATH` **unset**:

```powershell
$env:VK_LOADER_LAYERS_ENABLE = 'VK_LAYER_KHRONOS_validation'
$env:VK_LAYER_KHRONOS_VALIDATION_REPORT_FLAGS = 'error,warn,perf'
$env:RANDOVERLAY_INI = '<scratch test.ini>'
$env:RANDOVERLAY_NO_PROMPT = '1'
$env:MOCK_SECONDS = '8'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = '<...>\Vulkan-DLL-Version\build\rpcs3.exe'
$psi.WorkingDirectory = '<...>\Vulkan-DLL-Version\build'
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$out = $proc.StandardOutput.ReadToEnd(); $proc.WaitForExit()
"0x{0:X8}" -f $proc.ExitCode
```

Currently prints `0xC0000409` and no `[mock] exiting after N frames`. Fixed means exit
`0x00000000` plus the exit line.

Control (must keep passing) — same but with `VK_LOADER_LAYERS_ENABLE` removed: exit
`0x00000000`, ~15k-27k frames. Append two `[FileLog at ...]` lines mid-run and confirm
`Message:` lines appear in `build\layer_debug.log`.

## Out of scope — do not

- Do not modify the production dispatch/registration design or `install_layer.bat`.
- Do not disable, unregister, or otherwise interfere with OBS's `VK_LAYER_OBS_HOOK`; the
  layer must keep working alongside it.
- Do not attempt the real RPCS3/PCSX2 exclusive-fullscreen gate here — that is the parent
  plan's separate manual gate.
- Do not touch the AHK or PowerShell/WPF runtimes; this is Vulkan-renderer-only work.

## Open questions

- Is the fault in the layer's own recording, or in how validation wraps a handle the layer
  created? Best guess: the layer's own submit/record structs, since validation reports no
  API misuse before dying.
- Does the fault reproduce on another GPU vendor's ICD? Unknown — only NVIDIA was tested.
  If a fix proves elusive, this is worth checking to distinguish a layer bug from an
  NVIDIA-specific interaction.
