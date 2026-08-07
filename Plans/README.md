# RAC RandOverlay Plan Map

**Status:** Active index — the two current milestones are implemented and awaiting manual emulator/runtime verification; one non-blocking handoff is open
**Updated:** 2026-08-06 (Vulkan verification pass: build fix, apworld client verification, OBS coexistence proven)
**Branch:** `rac123-support`

## Organization Decision

Keep the plans separate. They share configuration and verification inputs, but they solve different problems and have independent failure modes:

| Plan | Canonical ownership | Depends on | Current state |
| --- | --- | --- | --- |
| [Multi-game overlay roadmap](multi-game-overlay-roadmap.md) | RAC1/RAC2/RAC3 product scope, branch/repository naming, shared `RandOverlay.ini` presets, README framing, and AHK/PowerShell-WPF behavior | None; this is the shared product/configuration track | Implementation complete; awaiting RAC1 RPCS3 plus RAC2/RAC3 PCSX2 visual/runtime checks |
| [Vulkan layer overlay](vulkan-overlay-works-no-matter-what.md) | Vulkan implicit-layer architecture, in-frame ImGui rendering, exclusive-fullscreen behavior, build/install workflow, and Vulkan-specific safety | Multi-game process mappings, active preset, visual settings, and log-path contract | Layer feature-complete with 34/34 unit tests; 2026-08-06 mock-host proof **with OBS capture layer active** (27704 frames, events rendered); awaiting real-emulator/fullscreen checks |

### Open handoffs

| Handoff | Scope | Blocking? |
| --- | --- | --- |
| [Vulkan validation-layer incompatibility](handoffs/2026-08-06-vulkan-validation-layer-incompatibility.md) | Layer dies with `0xC0000409` when `VK_LAYER_KHRONOS_validation` is enabled; leaves the three residual notes unaudited | No — does not block either plan reaching Completed |

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
   - Run `Test-RandOverlay.ps1` with the AutoHotkey runtime enabled.
   - Run `Vulkan-DLL-Version\tests\run_tests.bat` and confirm 34/34.
2. **External-window baseline (multi-game plan)**
   - RAC1 on RPCS3: verify overlay placement and `Ctrl+Alt+B` borderless toggle/restore.
   - RAC2 or RAC3 on PCSX2: verify preset process detection, placement, and borderless toggle/restore.
3. **In-frame Vulkan renderer (Vulkan plan)**
   - The layer is already registered in `HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers`. **Never set `VK_ADD_IMPLICIT_LAYER_PATH`** — a second discovery route for the same layer crashes the host.
   - Test RPCS3/RAC1 in windowed, borderless, and exclusive fullscreen.
   - Repeat at least one PCSX2/RAC2-or-RAC3 Vulkan case.
   - ~~Verify the RAC2/RAC3 `ClientComponent` labels match the Archipelago Launcher UI.~~ **Done 2026-08-06** — verified against the installed apworlds; RAC1 also corrected to its own apworld client.
   - ~~Ideally repeat one run with the Vulkan validation layer enabled.~~ **Blocked** — see the open handoff above. Retain `layer_debug.log` evidence from the normal runs instead.
4. **Closeout**
   - Record the emulator/client versions and results in the owning plan.
   - Change each plan to `Completed` independently when its own gates pass.

## Implementation Work That Can Start Without an Emulator

No unfinished code is required for the declared multi-game or Vulkan milestones; both are blocked only on manual runtime evidence. Additional coding should therefore be treated as a follow-on milestone rather than as completion work for either current plan.

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
