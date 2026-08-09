# RandOverlay Vulkan One-Click Distribution

**Status:** Completed - archived 2026-08-08
**Created:** 2026-08-08
**Goal:** Ship a safe, idempotent, selection-aware per-user installer for the precompiled Vulkan overlay, with a ZIP-first release, optional EXE bootstrapper, guided prerequisite remediation, repair/update/uninstall, and a path to trusted OSS signing.

## Decisions

- Release a precompiled payload; end users never need Git, MinGW, the Vulkan SDK, ImGui, or MinHook.
- Publish a release ZIP as the primary artifact and an optional EXE bootstrapper from the same payload.
- Install per-user under `%LOCALAPPDATA%\RandOverlay`; do not require elevation.
- Default to RAC1 only, with a multi-select for RAC1, RAC2, and RAC3.
- Preserve the tested mapping: RAC1 uses RPCS3; RAC2 and RAC3 use PCSX2.
- Require at least one game. Dependency gates apply only to selected games and are deduplicated.
- Use a resumable, idempotent staged setup. Register the layer only after capability checks pass.
- Offer confirmed WinGet remediation only for an allowlisted package; otherwise offer an official clickable link and recheck.
- Keep updates user-initiated through Status, Repair, Check for updates, Configure, and Uninstall.
- Send no telemetry. Network access occurs only after an explicit dependency/update/link action.
- Add an MIT license, privacy/network statement, deterministic release build, and SignPath eligibility documentation. Use Microsoft Artifact Signing as the fallback.

## Installer Contract

The installed layout is stable:

```text
%LOCALAPPDATA%\RandOverlay\
  current\RandOverlay_layer.dll
  current\RandOverlay_layer.json
  RandOverlay.ini
  Setup-RandOverlay.ps1
  setup-state.json
  rollback\previous\...
```

Setup stages and hashes a new payload before replacement, preserves configuration, keeps one rollback, closes only RandOverlay-owned stale registry values, and writes exactly one canonical value under `HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers`. It never modifies another Vulkan layer.

The game selection drives prerequisites:

| Selection | Emulator prerequisite | Archipelago component |
| --- | --- | --- |
| RAC1 | RPCS3 | Ratchet & Clank Client |
| RAC2 | PCSX2 | Ratchet & Clank 2 Client |
| RAC3 | PCSX2 | Ratchet and Clank 3 Client |

When multiple games are selected, setup asks for the initial active preset. Configure can change it later without reinstalling or changing the Vulkan registration.

## Dependency Policy

- Validate Windows x64, a Vulkan loader/device, Archipelago Launcher/log paths, selected clients, and selected emulator executables.
- PCSX2 may be installed through the allowlisted `PCSX2Team.PCSX2` WinGet package after confirmation.
- RPCS3, Archipelago, and GPU drivers use official download links plus Recheck; a generic Vulkan runtime is not treated as a GPU-driver substitute.
- Missing prerequisites save setup state and pause cleanly. Re-running Setup or Repair resumes.
- Compatibility is capability-based, not version-pinned. Unknown future versions warn but pass when required capabilities and scratch parser checks still work.

## Distribution And Trust

Each tag produces the ZIP, optional EXE, `SHA256SUMS.txt`, release metadata, and build provenance. Until trusted signing is active, documentation calls out expected Unknown Publisher/SmartScreen reputation warnings and tells users to verify the official release URL and SHA-256.

SignPath work requires an OSI-approved license, public documentation, a privacy statement, an already-published release, and a controlled public build. Both the setup executable and layer DLL must eventually be signed. A self-signed certificate is not presented as public trust.

## Verification

- PowerShell parse and installer unit tests.
- Fresh install into isolated test roots and registry keys.
- RAC1-only default; RAC2/RAC3 and combined selection dependency matrices.
- Missing dependency pause/resume and clickable-link fallback metadata.
- Repeated install, repair, configure, upgrade, rollback, stale-owned-registration cleanup, and uninstall.
- Hash/tamper rejection and deterministic ZIP rebuild.
- Existing 34/34 unit suite, `Test-RandOverlay.ps1`, validation/OBS scenarios, and RAC1/RAC2 visual assertions.
- Real RPCS3/RAC1 and PCSX2/RAC2 certification remains the final manual product gate.

## Completion

Move this plan to `Plans/Completed/` only after the distributable artifacts and automated installer suite pass. Signing-service acceptance and real-emulator certification may remain clearly labeled external/manual gates.

## Closeout - 2026-08-08

- Built the ZIP-primary release and optional embedded-payload EXE from the real Vulkan DLL.
- Added selection-aware RAC1-default setup, persistent portable dependency paths, clickable official links, allowlisted PCSX2 WinGet remediation, resumable prerequisite state, and no telemetry.
- Added idempotent install/configure/status/repair/update/uninstall, canonical registry ownership, unrelated-layer preservation, atomic replacement rollback, tamper rejection, preserved configuration, and one rollback payload.
- Added MIT licensing, privacy/network disclosure, third-party notices, signing guidance, and a pinned tag release workflow.
- Installer lifecycle, 34 units, AHK/PowerShell regression, normal/disabled/OBS/Khronos validation, and RAC1/RAC2 visual assertions pass in the shared `rac-overlay` target.
- Windows Defender scanned the local `dist` directory and reported no threats.
- Trusted signing still requires SignPath Foundation acceptance or Microsoft Artifact Signing. The built DLL and EXE are correctly documented as unsigned.
- Real RPCS3/RAC1 and PCSX2/RAC2 certification remains owned by the separate Vulkan renderer plan.
