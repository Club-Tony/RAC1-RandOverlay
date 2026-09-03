# RandOverlay Privacy And Network Activity

RandOverlay does not collect telemetry, analytics, crash reports, account data, game data,
or Archipelago messages. The Vulkan layer reads local Archipelago log files only to render
matching events inside a supported emulator frame.

The setup tool performs no network request during normal installation, status, repair,
configuration, or uninstall operations. It accesses the network only after the user
explicitly selects one of these actions:

- open an official dependency download page in the default browser;
- install an allowlisted dependency through Windows Package Manager (`winget`); or
- check the official `Club-Tony/RAC1-RandOverlay` GitHub Releases feed for an update.

Dependency and update requests go directly to the named third-party service. RandOverlay
does not receive a copy. Diagnostics are stored locally and redact the user profile path
when displayed or exported where practical.

Official dependency destinations are restricted to the Archipelago, RPCS3, PCSX2, GPU
vendor, Microsoft WinGet, Sony PlayStation support, and GitHub project pages documented in
the source repository (including the Ratchet & Clank apworld, multiplayer client, Lawrence,
and PopTracker projects).

Two further actions download files, and only when the user runs them: installing the RAC1
apworld fetches one file from the GitHub release URL pinned in the bundled stack manifest and
verifies its size and SHA-256 before placing it; refreshing that manifest fetches
`stack-manifest.json` and `SHA256SUMS.txt` from this project's own GitHub release and verifies
them. Nothing is downloaded from any other origin, nothing runs in the background, and the
tool never modifies RPCS3 or Archipelago configuration.
