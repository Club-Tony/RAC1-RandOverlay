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
.\Setup-RandOverlay.ps1 -Action InstallStackComponent -Component rac1-apworld
.\Setup-RandOverlay.ps1 -Action StackRollback -Component rac1-apworld
.\Setup-RandOverlay.ps1 -Action RefreshManifest
```

The default is RAC1/RPCS3. Game selection controls prerequisites, not the DLL. State is
installed under `%LOCALAPPDATA%\RandOverlay` and exactly one RandOverlay-owned manifest is
registered per user.

Every action appends a local, profile-path-redacted log under `%LOCALAPPDATA%\RandOverlay\logs`
(newest five kept; Status and Preflight log only once an install exists, and Uninstall removes
the folder). Exit codes: `0` success, `1` error, `2` missing prerequisites, `9` bootstrapper
payload failure. `-LoadOnly` dot-sources the engine's functions without running an action, which
is how a front-end or test can call `Get-PrerequisiteStatus` or `Compare-ReleaseVersion` directly.

`Status` and `Preflight` also report the RAC1 stack: Archipelago version and compatibility, the
RAC1 apworld and which pinned release it is, RPCS3 with firmware/game/multiplayer-PKG/network
status, and the optional Lawrence and PopTracker. These rows are informational and never change
the exit code. `InstallStackComponent` is the only action that writes outside the install root:
it downloads `rac1.apworld` from the exact GitHub release URL pinned in `stack-manifest.json`,
verifies size and SHA-256, keeps one backup of any file it replaces under `stack\rollback`, and
asks before replacing a file it does not recognise (exit `3` with `-NonInteractive` unless
`-ReplaceExisting`). Untested versions need `-AllowUntested`; revoked versions are always refused.
`RefreshManifest` fetches a newer manifest only from this project's own GitHub release and
verifies it against `SHA256SUMS.txt`. `Uninstall -RemoveManagedStack` deletes the apworld only if
Setup placed it and its bytes still match.

## Tests

```powershell
..\tests\installer\Test-Installer.ps1
..\tests\installer\Test-Stack.ps1
```

The isolated suite covers deterministic packaging, the self-contained BAT and EXE bootstraps, selection-aware
prerequisites, install/rerun/configure, unrelated-layer preservation, tamper detection,
repair, rollback, configuration preservation, and uninstall. It never writes production
Vulkan registration or Archipelago logs.

See the repo-root `SIGNING.md`, `PRIVACY.md`, and the Vulkan release workflow for trust,
network, and publication rules.
