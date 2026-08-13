# RAC Archipelago Session Launcher

**Status:** Completed - archived 2026-08-11
**Created:** 2026-08-11
**Type:** Handoff
**Goal:** One double-click that brings up a full RAC1/2/3 Archipelago session — preflight, host the seed, connect the client, start Lawrence, open PopTracker, launch the emulator and boot the title.

> **The deliverable does NOT live in this repo.** It is deliberately standalone and
> unversioned at `%USERPROFILE%\Desktop\Games\Emulators\RAC-AP-Launcher\`
> (`Play-RAC.bat`, `Start-RACSession.ps1`, `rac-launcher.config.json`, `README.md`).
> Only this plan is archived here. See also the persistent memory
> `[internal]`.

## Context

Playing RAC through Archipelago took ~8 manual steps with no automation anywhere. Nothing
in this repo covered it: the overlay only tails an existing Archipelago client log, and
`Setup-RandOverlay.ps1` only installs the Vulkan layer. This is a personal launcher, kept
deliberately separate from the RandOverlay installer, though it mirrors that installer's
`.bat` → `.ps1` split and its `Write-Ok`/`Write-Warn`/`Write-Fail` output conventions.

## Decisions

- Standalone and outside version control; all machine paths in `rac-launcher.config.json`
  so the engine itself stays generic and could be generalized later.
- Thin `.bat` entry point over a PowerShell engine — log-polling with timeouts, JSON
  config, and process/window checks are unmaintainable in pure batch.
- Every launch step idempotent: report and skip whatever is already running.
- Starts and focuses processes only. Never kills anything, never touches the Vulkan layer
  registration, never needs admin.
- Preflight runs **all** checks and prints everything before stopping, so one run surfaces
  every problem. Exit code 2 on missing prerequisites, matching `Setup-RandOverlay.ps1`.
- Lawrence's per-launch config wizard is not automatable; wait on its log rather than
  injecting keystrokes.

## What was verified, not assumed

| Claim | Mechanism |
|---|---|
| Seed hosts without the file dialog | `ArchipelagoServer.exe "<output\AP_*.zip>"` — confirmed live |
| RAC1 client auto-connects | `ArchipelagoTextClient.exe --connect host:port --name <slot>`, args from `CommonClient.pyc` |
| RAC2/RAC3 accept `--connect` but **not** `--name` | both use `get_base_parser()`; rac2 sets the slot only from an `.aprac2` file |
| Server readiness | `server listening on 0.0.0.0:38281` in the newest `logs\Server_*.txt` |
| Lawrence readiness | `Started Lawrence on` in `lawrence.log`, polled from a recorded byte offset |
| PopTracker preloads pack + AP | `--load-pack <uid> --pack-variant <v> --ap-host h:p --ap-slot <name>` |
| PCSX2 PINE (rac2/rac3 clients need it) | `EnablePINE = true`, slot 28011 |

## Scope added during implementation

**PopTracker integration**, once its CLI turned out to support everything needed. It
launches already loaded and already connected, is entirely optional (removing
`popTrackerExe` deletes the step), and can only ever emit `[OK]` or `[WARN]` — never a
preflight failure.

## Bugs found by running it

Three of these were only discoverable by executing the thing end to end:

1. **StrictMode 2.0 + single-item list** — a returned `List[T]` holding one item unrolls to
   a bare scalar with no `.Count`. Hit immediately, since only `[Mod.randomizer]` is
   enabled in Lawrence's `settings.toml`. Fix: `@()` at the call sites.
2. **Text Client process name** — one opened from the Archipelago Launcher GUI runs as
   `ArchipelagoLauncher`, not `ArchipelagoTextClient`, so the idempotence check missed it
   and would open a duplicate. Fix: also match on window title.
3. **PopTracker console attach** — it attaches to the parent console when started from one
   and buried the boot prompt under hundreds of log lines. Fix: `--no-console`. (It never
   creates a console itself, which is why double-clicking it shows no terminal.)
4. **Single-instance emulator collision** — starting the emulator bare and then starting a
   second process to boot a title fails with "Another instance of RPCS3 is running". Fix:
   ask about booting *first*, then start exactly one process with the boot target as an
   argument. This also keeps the prompt clear of the emulator's own console output.

## Outcome

Full RAC1 chain verified from a genuine cold start: seed hosted with no file dialog → text
client connected as `Clubs-RAC1` → Lawrence detected via log → PopTracker loaded with pack
and AP connection → RPCS3 booting Ratchet Multiplayer Utility as a single instance.

RAC2 and RAC3 correctly **fail preflight** on the player YAML — the current seed has a RAC1
slot only. That is the check working, not a defect. Their paths go live once seeds exist
for them.

## Follow-ups not done

- `rac2.apworld` has no `archipelago.json` manifest. Archipelago warns on every start and
  it will break outright on AP 0.7.0. Surfaced as a `[WARN]`.
- `ArchipelagoLauncher.exe "<component>" --connect ...` argument passthrough is still
  unconfirmed — the RAC2/RAC3 clients definitely parse `--connect`, but the Launcher's
  forwarding was never exercised. `-NoClientArgs` is the built-in fallback.
- The RaC1 PopTracker pack carries a local-only fix for a Glove of Doom crash, deliberately
  not reported upstream. Documented at
  `...\Ratchet & Clank Stuff (rpcs3)\PopTracker\LOCAL-PATCHES.md`.
