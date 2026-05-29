# RAC RandOverlay - Multi-Game Branch Naming And Overlay Roadmap

**Status:** Awaiting Manual Action — implementation complete 2026-04-25; remaining gates are manual-only emulator/runtime coverage the user must run (RAC1 on RPCS3 + at least one RAC2/RAC3 case on PCSX2)
**Created:** 2026-04-20
**Goal:** Reframe the non-main feature work so it clearly covers RAC1, RAC2, and RAC3 overlay support, then identify the next worthwhile improvements for the overlay beyond the current emulator and borderless work.

## Progress Update - 2026-04-25

- Multi-game README, shared `RandOverlay.ini`, AHK preset loading, PowerShell/WPF preset loading, and feedback issue template work are present in the working tree.
- AHK `#Warn` local/global collisions from label-scope temporary variables were cleaned up after startup exposed an `ow` collision in `ArchPositionOverlay()`.
- Added `Test-RandOverlay.ps1` as the local validation entry point. It covers Git whitespace, PowerShell parsing, GitHub issue-form shape, AHK `/iLib` parsing, and an AHK startup self-test with a temporary Archipelago log directory.
- Added a GitHub Actions workflow that installs AutoHotkey v1 and runs `Test-RandOverlay.ps1 -SkipAhkRuntime` on push and pull request events.
- Local checks passed through `.\Test-RandOverlay.ps1`.
- Remaining hands-on verification needs emulator/runtime coverage: RAC1 with RPCS3 and at least one RAC2 or RAC3 case with PCSX2.

## Current Status Snapshot

The repo currently has two practical signals:

- The repository name and README still present the project as RAC1-specific.
- The non-main feature branch already moved beyond that framing by adding broader emulator support and borderless-window behavior.

Current branch state:

- `main` is still tied to the older RAC1 presentation.
- `rac123-support` is the active feature branch that is already moving toward broader compatibility.

That means naming has fallen behind scope.

## Immediate Naming Problem

The active non-main branch name is accurate about emulator handling, but it does not clearly signal game-family scope.

If the branch is intended to represent support for RAC1, RAC2, and RAC3 workflows, rename it before more work accumulates.

## Recommended Branch Rename

Use this exact branch name:

`rac123-support`

Reasoning:

- It is broad enough for emulator and UI work.
- It does not lock the branch to borderless mode only.
- It makes RAC2 and RAC3 inclusion obvious without being overly verbose.

## Repo-Level Naming Follow-Up

If the feature branch proves successful, consider whether the repository name itself should eventually be generalized.

Possible future repo names:

- `RAC-RandOverlay`
- `RAC123-RandOverlay`
- `RAC-Archipelago-Overlay`

This is optional for now. Branch naming should be fixed first.

## Scope Areas For The Next Overlay Iteration

### Phase 1 - Multi-Game Framing

- Update branch name to reflect RAC1, RAC2, and RAC3 scope.
- Update README copy so it no longer describes the overlay as RAC1-only.
- Explicitly document current emulator support and tested combinations.

### Phase 2 - Game / Emulator Presets

- Add per-game preset profiles for RAC1, RAC2, and RAC3.
- Allow different colors, vertical offsets, opacity, and font presets by game.
- Make emulator-process matching configurable rather than embedded in one script path.

### Phase 3 - Overlay Quality-Of-Life

- Add a config file instead of hard-coding all style values.
- Add position presets such as top-center, top-left, bottom-center, and custom offsets.
- Add a hotkey for click-through toggle separate from overlay on/off.
- Add a hotkey for opacity cycling.
- Add a hotkey for size scaling.

### Phase 4 - Message UX Improvements

- Support a short message stack instead of only a single line at a time.
- Allow event filtering by category such as items, goals, deaths, or system chatter.
- Add optional color rules by message type instead of a single color mapping file.
- Add an optional fade mode for less disruptive presentation during gameplay.

### Phase 5 - Input / Source Improvements

- Improve log-source detection so the overlay survives client restarts more gracefully.
- Consider a more direct data source than raw log polling if Archipelago tooling makes that practical later.
- Add resilience around missing or rotating log files.

## Other Overlay Ideas Worth Considering

These are not all mandatory, but they are the most plausible next upgrades:

1. Per-game visual themes so RAC1, RAC2, and RAC3 feel intentionally distinct.
2. A recent-event history panel that can be toggled temporarily.
3. A compact "streamer mode" with smaller text and quieter colors.
4. Optional sound cues for high-value events.
5. A dead-simple tray or hotkey menu for live configuration changes.
6. Preset export/import so setups can be shared between machines.
7. Separate fullscreen-handling logic for RPCS3 and PCSX2 if their window behavior diverges.
8. Optional "pin overlay to current monitor" behavior for multi-monitor setups.

## Recommended Next Milestone

Prioritize the smallest coherent package:

1. Rename the active non-main branch to a multi-game name.
2. Update README and repo wording to stop implying RAC1-only scope.
3. Add a small config file for game/emulator presets.
4. Smoke-test RAC1, RAC2, and RAC3 scenarios against the supported emulator windows.

That would align repo language, branch language, and actual behavior.

## Verification

Treat the milestone as complete only when:

1. The active feature branch name no longer implies a single-game scope.
2. README language reflects multi-game support accurately.
3. The overlay positions correctly for at least one RAC1 case and one RAC2 or RAC3 case.
4. Borderless toggle still works after the naming and preset refactor.
5. No regression appears in the existing AHK and PowerShell/WPF entry points.

### Automated Verification Run - 2026-05-16

Unattended sweep on branch `rac123-support`. Tooling: PowerShell + AutoHotkey v1.1.37.02 (real runtime, not skipped).

- **Criterion 1 — branch scope: PASS.** Active branch `rac123-support` clearly implies RAC1/2/3 multi-game scope, not a single game.
- **Criterion 2 — README multi-game language: PASS.** README documents experimental RAC1/RAC2/RAC3 preset support, the PCSX2/RPCS3 process-name table, and the `ActivePreset=RAC1|RAC2|RAC3` switch.
- **Criterion 5 — no regression in entry points: PASS.** `Test-RandOverlay.ps1 -AutoHotkeyPath <AHK v1>` ran the full suite, all 7 checks green and exit 0: Resolve AutoHotkey, Git diff whitespace, PowerShell parser, GitHub issue-form shape, GitHub Actions workflow shape, **AHK /iLib parse** (live AHK v1), **AHK startup self-test**. This is the same suite the `.github/workflows/validate.yml` CI runs (here with the AHK runtime *enabled*, exceeding CI which uses `-SkipAhkRuntime`).
- **Criteria 3 & 4 — KNOWN-MANUAL.** Overlay positioning over an RAC1 (RPCS3) case and an RAC2/RAC3 (PCSX2) case, and the borderless-toggle behavior after the preset refactor, require running the emulators and visually confirming overlay placement. Cannot be automated headlessly — these stay on the manual queue and are the only gates remaining.

Net: 3 of 5 completion criteria are auto-verified PASS; the milestone is blocked solely on the two emulator/visual criteria.

## Risks

- The repo name may continue to confuse users even if the branch name is fixed.
- PCSX2 and RPCS3 window behavior may require separate assumptions instead of one generic path.
- More presets and hotkeys can make the script feel less lightweight if not organized cleanly.
- README and branch naming changes can get ahead of real tested support if verification is weak.

## When

Medium priority.

The branch already points toward broader scope, so this is a good moment to align naming and roadmap before the overlay accumulates more game-specific behavior under RAC1-only labels.
