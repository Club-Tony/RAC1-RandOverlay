# Linux Certification Runbook

**Status:** Awaiting Manual Action
**Created:** 2026-08-13
**Type:** Handoff

The Linux layer is code-complete and passing 15/15 live tests under lavapipe,
locally and in CI. What software rendering cannot prove is covered here.

Run this on real hardware — a live USB with persistence, a dual-boot install, or
a Steam Deck. **Not** in Hyper-V or VirtualBox: neither gives a Linux guest a
Vulkan device, so RPCS3 falls back to software and none of these gates are
meaningful. For the two items that don't need a GPU, see
`tests/run_desktop_integration_tests.sh` instead — those do run in a plain VM.

## What this closes

| Gate | Why software rendering can't prove it |
|---|---|
| Overlay draws over a real game in fullscreen | No compositor, no real display |
| Present queue family ≠ 0 | lavapipe exposes exactly one queue family, so the layer's `queueFamily = 0` assumption is never tested |
| Real driver swapchain behaviour | RADV/NVIDIA recreate swapchains differently from llvmpipe |
| Frame-time cost | Meaningless at llvmpipe speeds |

## Prerequisites

- Ubuntu 24.04 (or SteamOS) on real hardware with a working GPU driver.
  Confirm before anything else: `vulkaninfo --summary` must report your actual
  GPU, not `llvmpipe`. If it says llvmpipe, stop — nothing below is valid.
- RPCS3 (RAC1) and optionally PCSX2 (RAC2/RAC3), **Vulkan renderer selected**.
- A RAC1 dump and a working Archipelago seed + client.
- Build deps:
  ```
  sudo apt install -y build-essential cmake pkg-config libvulkan-dev \
    vulkan-tools mesa-vulkan-drivers vulkan-validationlayers \
    libfontconfig1-dev libxcb1-dev xvfb
  ```

## 1 — Build and self-check

```
git clone https://github.com/Club-Tony/RAC1-RandOverlay.git
cd RAC1-RandOverlay/Vulkan-DLL-Version
git clone https://github.com/ocornut/imgui.git deps/imgui
git -C deps/imgui checkout 8314fc3e5a10f7c6b670225065fce1dc8cfd396b

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DRANDOVERLAY_FETCH_DEPS=OFF
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
./install_layer.sh --build-dir build
./install_layer.sh --status
```

Then run the automated suite **on the real GPU** — this is not a repeat of CI,
because it is the first time the layer runs against a driver with more than one
queue family:

```
./tests/run_live_tests.sh all
```

Expected: 15/15. A failure here is a real-driver bug, not an environment
problem. Capture `/tmp/randoverlay-live/mock_event.txt` if so.

**If `run_live_tests.sh` passes on real hardware, the queue-family gate is
closed** — the mock host picks the first graphics+present family, and on most
GPUs that is not the only one available.

## 2 — Real emulator, windowed

1. Start the Archipelago client for RAC1.
2. Start RPCS3 (Vulkan renderer), boot RAC1, **windowed**.
3. Trigger or await an Archipelago event.

Pass: the overlay text appears centred at ~17% from the top and fades after 5s.
Check `~/.local/share/RandOverlay/layer_debug.log` — expect
`process=rpcs3 … disabled=0`, a swapchain line, and a `Message:` line.

## 3 — Fullscreen

⚠️ **Read this before testing.** "Exclusive fullscreen" is a Windows concept —
`VK_EXT_full_screen_exclusive` is a Windows-only extension and does not exist on
Linux. The Linux equivalent is the compositor handing the window **direct
scanout** (bypassing composition). That is the case to test, because it is the
one where a normal top-most overlay window would be bypassed.

Test each and record separately:

| Mode | How |
|---|---|
| Borderless fullscreen | RPCS3 fullscreen toggle on a normal desktop session |
| Direct scanout / unredirected | KDE: disable compositing (Alt+Shift+F12) then fullscreen. GNOME: fullscreen usually unredirects automatically. Steam Deck: gamescope session |
| gamescope (if available) | `gamescope -f -- rpcs3` |

Pass: overlay is visible in all three. A failure specifically under direct
scanout is the most interesting possible result and should be captured with the
layer log plus the compositor name and version.

## 4 — RAC2 / RAC3 (optional)

Linux cannot read PCSX2's window title, so the layer uses the ini instead. Set
`ActivePreset=RAC2` (or `RAC3`) and confirm the layer log shows:

```
RAC2/RAC3 both enabled and window titles are unreadable on this platform;
using ActivePreset=… from the ini
```

Then verify events appear for that game. Switching `ActivePreset` and
restarting the emulator should switch the preset.

## 5 — Frame-time sanity

Enable RPCS3's frame counter, or run under `mangohud rpcs3`. Compare average FPS
in a fixed area with `DISABLE_RANDOVERLAY=1` and without. The layer polls the
log only every `PollMs` and records one extra command buffer per frame, so any
measurable regression is a bug worth filing.

## Recording results

Update the verification table in `Plans/linux-vulkan-layer-port.md` and move it
to `Plans/Completed/` once every gate above passes — per repo plan hygiene, that
means the `git mv` plus a scoped commit in the same step.

Keep the layer log from each mode as evidence:

```
cp ~/.local/share/RandOverlay/layer_debug.log \
   /tmp/randoverlay-cert-<mode>.log
```

## If something fails

- **Overlay never appears, no debug log** — the layer did not load. Check
  `./install_layer.sh --status`, then whether the emulator is Flatpak'd (see
  the Flatpak section of `Vulkan-DLL-Version/README.md`).
- **Log exists, `disabled=1`** — process gate rejected the host. Check the
  `process=` value; an AppImage or wrapper may report an unexpected name.
- **Log exists, gate active, no `Message:`** — the log directory is wrong.
  Check the `logDir=` line and set `LogDirLinux` in the ini.
- **Overlay appears then the game crashes on alt-tab or resolution change** —
  that is the swapchain rebuild path. It is clean under validation with
  lavapipe, but a real driver may differ. Re-run
  `./tests/run_live_tests.sh recreate` and attach the output.
- **Never set `VK_ADD_IMPLICIT_LAYER_PATH`** while the manifest is installed
  normally. Two discovery routes for one layer crash the host.
