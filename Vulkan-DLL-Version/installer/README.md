# RandOverlay Vulkan Installer Development

The distributed installer is built from a compiled layer DLL and tracked repository source.
End users do not need Git, MinGW, the Vulkan SDK, ImGui, or MinHook.

## Build a release

```powershell
..\build.bat --no-pause
.\Build-RandOverlayRelease.ps1 -Format Bat,Zip,Exe
```

Outputs are written to `Vulkan-DLL-Version\dist`: a primary self-contained BAT, the
transparent release ZIP, an optional EXE bootstrapper, and `SHA256SUMS.txt`. The ZIP has fixed
entry ordering and timestamps. Both bootstrappers carry that exact ZIP, verify its SHA-256
before extraction, and launch the same setup script. The BAT clearly explains this handoff.
ZIP users can double-click `Install-RandOverlay.bat` after extraction.

## Setup actions

```powershell
.\Setup-RandOverlay.ps1
.\Setup-RandOverlay.ps1 -Action Status
.\Setup-RandOverlay.ps1 -Action Repair
.\Setup-RandOverlay.ps1 -Action Configure -Games RAC1,RAC2 -ActiveGame RAC2
.\Setup-RandOverlay.ps1 -Action CheckForUpdates
.\Setup-RandOverlay.ps1 -Action Uninstall
```

The default is RAC1/RPCS3. Game selection controls prerequisites, not the DLL. State is
installed under `%LOCALAPPDATA%\RandOverlay` and exactly one RandOverlay-owned manifest is
registered per user.

## Tests

```powershell
..\tests\installer\Test-Installer.ps1
```

The isolated suite covers deterministic packaging, the self-contained BAT and EXE bootstraps, selection-aware
prerequisites, install/rerun/configure, unrelated-layer preservation, tamper detection,
repair, rollback, configuration preservation, and uninstall. It never writes production
Vulkan registration or Archipelago logs.

See the repo-root `SIGNING.md`, `PRIVACY.md`, and the Vulkan release workflow for trust,
network, and publication rules.
