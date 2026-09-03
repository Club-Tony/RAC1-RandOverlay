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
.\Setup-RandOverlay.ps1 -Action InstallStackComponent -Component poptracker -AllowUntested
.\Setup-RandOverlay.ps1 -Action InstallStackComponent -Component rac1-multiplayer -AllowUntested
.\Setup-RandOverlay.ps1 -Action StackRollback -Component rac1-apworld
.\Setup-RandOverlay.ps1 -Action RefreshManifest
.\Setup-RandOverlay.ps1 -Action ConfigureRpcs3Network
.\Setup-RandOverlay.ps1 -Action Launch -Target poptracker
```

The default is RAC1/RPCS3. Game selection controls prerequisites, not the DLL. State is
installed under `%LOCALAPPDATA%\RandOverlay` and exactly one RandOverlay-owned manifest is
registered per user.

The engine is `Setup-RandOverlay.ps1` plus the stack library it dot-sources from `lib\`;
both travel together into the release package and into the install root, so a released
install and a repo checkout run the same code.

Every action appends a local, profile-path-redacted log under `%LOCALAPPDATA%\RandOverlay\logs`
(newest five kept; Status and Preflight log only once an install exists, and Uninstall removes
the folder). Exit codes: `0` success, `1` error, `2` missing prerequisites, `9` bootstrapper
payload failure. `-LoadOnly` dot-sources the engine's functions without running an action, which
is how a front-end or test can call `Get-PrerequisiteStatus` or `Compare-ReleaseVersion` directly.

`Status` and `Preflight` also report the RAC1 stack: Archipelago version and compatibility, the
RAC1 apworld and which pinned release it is, RPCS3 with firmware/game/multiplayer-PKG/network
status, and the optional Lawrence and PopTracker. These rows are informational and never change
the exit code.

`InstallStackComponent` installs whichever component the manifest marks managed. Every one is
pinned to an exact GitHub release URL with a SHA-256 and byte size that are checked before the
file is placed; untested versions need `-AllowUntested` and revoked versions are always refused.
One backup of anything it replaces is kept under `stack\rollback`, and it asks before replacing
something it does not recognise (exit `3` with `-NonInteractive` unless `-ReplaceExisting`).

- `rac1-apworld` is the only component written outside the install root, into Archipelago's
  `custom_worlds`.
- `poptracker` keeps a portable copy under `stack\PopTracker` with a `portable.txt` marker.
  A PopTracker you installed yourself is only ever reported, never changed or removed. No
  Ratchet & Clank tracker pack ships with this tool, because neither published pack states a
  license; add one to the `packs` folder yourself.
- `rac1-multiplayer` downloads and verifies the PKG into `stack\downloads` and stops there.
  Installing it is a manual step in RPCS3 (File > Install Packages/Raps/Edats); nothing is
  ever written into `dev_hdd0`.

`ConfigureRpcs3Network` is the one action that edits another program's configuration. It
refuses to run while RPCS3 is open, backs up `config.yml` and verifies the backup first,
rewrites only the `Internet enabled:` line, and is undone by `StackRollback -Component
rpcs3-network`. `Launch` starts Archipelago, RPCS3, PopTracker or a Lawrence build you point
at with `-LawrencePath`; it is interactive only. Lawrence is never downloaded, because it
carries no license.

`RefreshManifest` fetches a newer manifest only from this project's own GitHub release and
verifies it against `SHA256SUMS.txt`. `Uninstall -RemoveManagedStack` deletes the apworld only
if Setup placed it and its bytes still match. Uninstall keeps PopTracker packs, saves and
settings unless `-RemoveTrackerData` is given.

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
