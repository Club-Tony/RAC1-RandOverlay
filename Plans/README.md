# RAC RandOverlay Plan Map

**Status:** Active index — the external-renderer milestone is complete; the Vulkan milestone awaits only live RPCS3/PCSX2 certification; two non-blocking hardening handoffs are open
**Updated:** 2026-08-08 (validation incompatibility fixed; committed RAC1/RAC2 visual runner added)
**Branch:** `rac123-support`

## Organization Decision

Keep the plans separate. They share configuration and verification inputs, but they solve different problems and have independent failure modes:

| Plan | Canonical ownership | Depends on | Current state |
| --- | --- | --- | --- |
| [Multi-game overlay roadmap](Completed/multi-game-overlay-roadmap.md) | RAC1/RAC2/RAC3 product scope, branch/repository naming, shared `RandOverlay.ini` presets, README framing, and AHK/PowerShell-WPF behavior | None; this is the shared product/configuration track | **Completed 2026-08-08** — owner-confirmed across RAC1/RAC2/RAC3; automated AHK/WPF regression passes |
| [Vulkan layer overlay](vulkan-overlay-works-no-matter-what.md) | Vulkan implicit-layer architecture, in-frame ImGui rendering, exclusive-fullscreen behavior, build/install workflow, and Vulkan-specific safety | Multi-game process mappings, active preset, visual settings, and log-path contract | Automated suite passes, including Khronos validation and OBS coexistence; awaiting live RPCS3/RAC1 and PCSX2/RAC2 certification |
| [Vulkan one-click distribution](Completed/vulkan-one-click-installer.md) | Precompiled ZIP/EXE release, per-user setup, dependency remediation, repair/update/uninstall, and signing eligibility | Passing Vulkan build and stable RAC1/RAC2/RAC3 preset contract | **Completed 2026-08-08** — local artifacts and full automated suite pass; signing remains an external service gate |

### Open handoffs

| Handoff | Scope | Blocking? |
| --- | --- | --- |
| [Present queue-family selection](handoffs/2026-08-08-vulkan-present-queue-family-selection.md) | Track the actual presentation queue family instead of assuming the first device queue family | No — current RPCS3/PCSX2 and validation paths use family 0 |
| [`OUT_OF_DATE` semaphore lifecycle](handoffs/2026-08-08-vulkan-out-of-date-semaphore-lifecycle.md) | Add deterministic swapchain-out-of-date coverage for overlay semaphore reuse and recreation | No — normal recreation already idles and rebuilds resources |

A single super-plan would mix the external-window and in-frame renderers, make one status line ambiguous, and duplicate their implementation histories. This index is the only shared coordination layer; implementation detail remains in the owning plan.

## Shared Contracts

The following are cross-plan contracts and should have one source of truth in code/configuration rather than being redefined in either plan:

- `RandOverlay.ini` owns the active RAC1/RAC2/RAC3 preset, emulator process names, Archipelago client component, colors, font choices, vertical position, polling, and display/fade timing.
- `README.md` owns user-facing support claims and launch instructions.
- The multi-game plan owns behavior expected from the AHK and PowerShell/WPF external-window runtimes.
- The Vulkan plan consumes the same preset and display contract, but owns only the in-frame Vulkan renderer and its build/install/runtime safety.
- Support is not promoted beyond “experimental” for an emulator/game combination until its applicable manual checks below pass.

When a shared contract changes, update both implementations and their tests in the same working change, then record renderer-specific consequences only in the relevant plan.

## Canonical Manual Verification Sequence

Run the checks in this order so later failures are attributable to the renderer rather than shared configuration:

1. **Automated baseline**
   - Run `.\Vulkan-DLL-Version\tests\run_live_tests.ps1 -Mode all -KeepArtifacts` (Windows)
     or `./Vulkan-DLL-Version/tests/run_live_tests.sh all` (Linux).
   - This covers 34/34 units, `Test-RandOverlay.ps1`, normal/disabled/OBS/validation scenarios, and RAC1/RAC2 visual assertions.
2. **External-window milestone (multi-game plan) — complete**
   - Owner-confirmed AHK and PowerShell/WPF behavior across RAC1, RAC2, and RAC3.
   - Existing regression checks remain; no new external-window automation is planned.
3. **In-frame Vulkan renderer (Vulkan plan) — remaining manual gate**
   - The layer is already registered in `HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers`. **Never set `VK_ADD_IMPLICIT_LAYER_PATH`** — a second discovery route for the same layer crashes the host.
   - Test RPCS3/RAC1 in windowed, borderless, and exclusive fullscreen.
   - Test PCSX2/RAC2 in every applicable mode.
   - Trigger or observe an Archipelago event in each case and confirm it renders inside the game frame.
   - ~~Verify the RAC2/RAC3 `ClientComponent` labels match the Archipelago Launcher UI.~~ **Done 2026-08-06** — verified against the installed apworlds; RAC1 also corrected to its own apworld client.
   - ~~Repeat one run with the Vulkan validation layer enabled.~~ **Done 2026-08-08** — clean exit, zero validation errors, and no function-resolution warnings.
4. **Closeout**
   - Record the emulator/client versions and results in the owning plan.
   - Change each plan to `Completed` independently when its own gates pass.

## Implementation Work That Can Start Without an Emulator

No unfinished blocking code remains. The external-renderer plan is complete and the Vulkan plan awaits only manual real-emulator evidence. Additional coding should therefore be treated as a follow-on milestone rather than completion work.

The safest first follow-on is **test-only parser parity**:

1. Add a shared synthetic Archipelago log fixture corpus and expected normalized messages.
2. Exercise the AHK, PowerShell/WPF, and Vulkan parsers against those fixtures without changing runtime behavior.
3. Use the parity tests as a safety net before changing event filtering or message scheduling.

After that baseline, the highest-value behavior work from the multi-game backlog is:

- Replace newest-message-only behavior with a bounded FIFO so burst events are displayed in order.
- Tail logs by byte offset with partial-line buffering and recovery from rotation, truncation, late client startup, and client restarts.
- Add deterministic timing seams so polling, fade, queue overflow, and toggle behavior can be tested without real-time sleeps.

Those changes are shared behavior work. They should be planned once under the multi-game track, then implemented with explicit parity across all enabled renderers; they should not be copied into the Vulkan plan as a second backlog.

## Maintenance Rule

- Keep renderer-specific design, diagnostics, and verification in that renderer’s plan.
- Keep shared product behavior and future event/log UX in the multi-game plan.
- Add only links and dependency notes across plans; do not duplicate task lists.
- Add any future renderer (for example, a separately scoped optional backend) as its own plan and link it from this index.
