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

A few further actions download files, and only when the user runs them by name. Installing a
managed stack component fetches one file from the exact GitHub release URL pinned in the
bundled stack manifest and verifies its size and SHA-256 before placing it; this covers the
RAC1 apworld, the Ratchet & Clank multiplayer PKG, and the optional portable PopTracker copy.
Refreshing that manifest fetches `stack-manifest.json` and `SHA256SUMS.txt` from this
project's own GitHub release and verifies them. Nothing is downloaded from any other origin,
and nothing runs in the background.

The tool never modifies Archipelago configuration, and never modifies RPCS3 configuration
except through the explicit `ConfigureRpcs3Network` action. That action refuses to run while
RPCS3 is open, copies `config.yml` to `stack\rollback` and verifies the copy before editing,
rewrites only the `Internet enabled:` line, and can be undone with `StackRollback -Component
rpcs3-network`. The multiplayer PKG is downloaded and verified but never written into RPCS3;
installing it stays a manual step in RPCS3 itself.
