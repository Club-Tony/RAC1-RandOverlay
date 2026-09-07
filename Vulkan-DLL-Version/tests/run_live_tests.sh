#!/usr/bin/env bash
# Linux live tests for the RandOverlay implicit Vulkan layer — the counterpart
# of run_live_tests.ps1.
#
# Drives the mock Vulkan host (built as `rpcs3`, so the process gate activates)
# through a real present loop under lavapipe, injects synthetic Archipelago
# events, and asserts on the presented image via headless readback rather than
# a desktop screenshot.
#
#   ./run_live_tests.sh                 all modes
#   ./run_live_tests.sh preflight       environment only
#   ./run_live_tests.sh visual          overlay actually draws
#   ./run_live_tests.sh validation      Khronos validation is clean
#
# Requires an X server. Under CI use: xvfb-run -a ./run_live_tests.sh
set -uo pipefail

MODE="${1:-all}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd -- "$HERE/.." && pwd)"
BUILD="${RANDOVERLAY_BUILD_DIR:-$PROJ/build/linux}"
MOCK="$BUILD/rpcs3"
SCRATCH="${RANDOVERLAY_SCRATCH:-${TMPDIR:-/tmp}/randoverlay-live}"

pass=0; fail=0
if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
ok()   { pass=$((pass+1)); printf '  %s[PASS]%s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { fail=$((fail+1)); printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$1"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }

# ── Environment ───────────────────────────────────────────────────────────────
find_icd() {
    find /usr/share/vulkan/icd.d /usr/local/share/vulkan/icd.d \
         -name 'lvp_icd*.json' 2>/dev/null | head -1
}

echo "=== RandOverlay Linux live tests (mode: $MODE) ==="
echo
echo "[preflight]"

[ -x "$MOCK" ] && ok "mock host built ($MOCK)" || {
    bad "mock host missing at $MOCK"
    echo "    Build it: cmake -S $PROJ -B $BUILD && cmake --build $BUILD -j"
    exit 1
}

ICD="$(find_icd)"
if [ -n "$ICD" ]; then ok "software ICD found"; note "$ICD"; export VK_ICD_FILENAMES="$ICD"
else bad "no lavapipe ICD (install mesa-vulkan-drivers)"; exit 1; fi

if [ -n "${DISPLAY:-}" ]; then ok "DISPLAY is set ($DISPLAY)"
else bad "no DISPLAY — run under: xvfb-run -a $0 $MODE"; exit 1; fi

MANIFEST="${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/implicit_layer.d/RandOverlay_layer.json"
if [ -f "$MANIFEST" ]; then
    ok "layer registered"
    LAYER_SO=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$MANIFEST")
    LAYER_LOG="$(dirname "$LAYER_SO")/layer_debug.log"
    note "$LAYER_SO"
else
    bad "layer not registered — run install_layer.sh first"
    exit 1
fi

[ "$MODE" = "preflight" ] && { echo; echo "=== $pass passed, $fail failed ==="; exit $((fail>0)); }

# ── Scratch config ────────────────────────────────────────────────────────────
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/logs"
INI="$SCRATCH/RandOverlay.ini"
cat > "$INI" <<EOF
[General]
ActivePreset=RAC1
EnabledPresets=RAC1
LogDirLinux=$SCRATCH/logs
; Far longer than any run, so the readback assertion measures whether the
; overlay DREW rather than racing its fade-out. Shipping default is 5000.
DisplayMs=60000
PollMs=500
FadeInMs=100
FadeOutMs=200

[Preset.RAC1]
EmulatorProcesses=rpcs3
OverlayColor=#80A0D0
BackgroundColor=#1E1E1E
VerticalPercent=0.17
VulkanFontSize=48
FontFamilyLinux=DejaVu Sans
FontFallbackLinux=DejaVu Sans
EOF

LOGFILE="$SCRATCH/logs/Client_livetest.txt"

# Without this the Khronos validation layer loads but reports nowhere unless the
# application registers a debug messenger, which the mock host deliberately does
# not do (a real emulator would not either).
SETTINGS="$SCRATCH/vk_layer_settings.txt"
cat > "$SETTINGS" <<EOF
khronos_validation.debug_action = VK_DBG_LAYER_ACTION_LOG_MSG
khronos_validation.log_filename = stdout
khronos_validation.report_flags = error,warn,info
EOF

# Runs the mock host, optionally injecting an event mid-run.
# $1 = "event" | "control"; $2 = extra env prefix (e.g. validation)
run_host() {
    local kind="$1"; shift
    : > "$LOGFILE"
    echo "seed line ignored" >> "$LOGFILE"
    rm -f "$LAYER_LOG" "$SCRATCH/frame.ppm"

    RANDOVERLAY_INI="$INI" RANDOVERLAY_NO_PROMPT=1 \
    MOCK_SECONDS=8 MOCK_STATIC_FRAME=1 MOCK_READBACK=1 \
    MOCK_RECREATE="${MOCK_EXTRA_RECREATE:-0}" \
    MOCK_READBACK_PPM="$SCRATCH/frame.ppm" \
    "$@" "$MOCK" > "$SCRATCH/mock_$kind.txt" 2>&1 &
    local pid=$!

    if [ "$kind" = "event" ]; then
        sleep 2
        echo "[Client at 12:00:00]: Ratchet found their Hydrodisplacer (RAC1)" >> "$LOGFILE"
    fi
    wait $pid
}

band_differing() {
    sed -n 's/.*\[mock-readback\].*differing=\([0-9]*\).*/\1/p' "$1" | tail -1
}

# ── Visual: does the overlay actually reach the presented image? ──────────────
if [ "$MODE" = "all" ] || [ "$MODE" = "visual" ]; then
    echo
    echo "[visual]"

    # Control: identical run with the layer switched off via its own kill
    # switch. This is what makes the pixel count meaningful — it shows the
    # overlay band is empty without the layer, so a non-zero count in the event
    # run can only have come from the layer drawing into the frame.
    run_host control env DISABLE_RANDOVERLAY=1
    ctrl=$(band_differing "$SCRATCH/mock_control.txt")
    ctrl=${ctrl:-unknown}

    run_host event
    evt=$(band_differing "$SCRATCH/mock_event.txt")
    evt=${evt:-unknown}

    if grep -q "process=rpcs3.*disabled=0" "$LAYER_LOG" 2>/dev/null; then
        ok "process gate activated for the mock host"
    else
        bad "process gate did not activate"
        [ -f "$LAYER_LOG" ] && head -5 "$LAYER_LOG"
    fi

    if grep -qE "vkCreateSwapchainKHR|Swapchain:" "$LAYER_LOG" 2>/dev/null; then
        ok "layer saw the swapchain"
    else
        bad "layer never saw a swapchain"
    fi

    if grep -q "Message:" "$LAYER_LOG" 2>/dev/null; then
        ok "layer picked up the injected Archipelago event"
        note "$(grep -m1 'Message:' "$LAYER_LOG")"
    else
        bad "layer never reported the injected event"
    fi

    note "overlay-band differing pixels — control=$ctrl event=$evt"
    if [ "$evt" != "unknown" ] && [ "$ctrl" != "unknown" ]; then
        if [ "$ctrl" -eq 0 ]; then
            ok "overlay band is empty with the layer disabled (clean control)"
        else
            bad "control frame is not clean (differing=$ctrl) — the pixel test cannot discriminate"
        fi
        if [ "$evt" -gt 2000 ]; then
            ok "overlay pixels present in the event frame"
        else
            bad "overlay band looks empty in the event frame (differing=$evt)"
        fi
        [ -f "$SCRATCH/frame.ppm" ] && ok "captured frame written" && note "$SCRATCH/frame.ppm"
    else
        bad "readback produced no measurement"
    fi
fi

# ── Validation: is the dispatch chain clean under Khronos validation? ─────────
if [ "$MODE" = "all" ] || [ "$MODE" = "validation" ]; then
    echo
    echo "[validation]"
    if ! ls /usr/share/vulkan/explicit_layer.d/*validation*.json >/dev/null 2>&1; then
        note "vulkan-validationlayers not installed — skipping"
    else
        # VK_INSTANCE_LAYERS works on every loader; VK_LOADER_LAYERS_ENABLE only
        # exists from 1.3.234, and Ubuntu 22.04 ships 1.3.204. Set both.
        run_host event env \
            VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
            VK_LOADER_LAYERS_ENABLE=VK_LAYER_KHRONOS_validation \
            VK_LAYER_SETTINGS_PATH="$SETTINGS"

        # Prove the validation layer actually ran before trusting a zero error
        # count. Without this the test silently passes when validation fails to
        # load, which is exactly how it passed the first time it was written.
        if grep -q 'Khronos Validation Layer Active' "$SCRATCH/mock_event.txt"; then
            ok "Khronos validation layer loaded alongside RandOverlay"
        else
            bad "validation layer never loaded — a zero error count proves nothing"
            note "check VK_INSTANCE_LAYERS support and $SETTINGS"
        fi

        errs=$(grep -cE 'Validation Error|VUID-' "$SCRATCH/mock_event.txt")
        if [ "${errs:-0}" -eq 0 ]; then
            ok "no validation errors over a real present loop"
        else
            bad "$errs validation error line(s)"
            grep -E 'Validation Error|VUID-' "$SCRATCH/mock_event.txt" | head -10
        fi
    fi
fi

# ── Swapchain rebuild: the layer's per-swapchain lifecycle ───────────────────
# The layer allocates a semaphore and a command buffer per swapchain image.
# Plans/handoffs/ flags the teardown/re-init path as untested, and Mesa
# recreates swapchains differently from the Windows drivers it was written
# against, so exercise it repeatedly with validation watching for leaks.
if [ "$MODE" = "all" ] || [ "$MODE" = "recreate" ]; then
    echo
    echo "[swapchain recreation]"
    MOCK_EXTRA_RECREATE=4 run_host event env \
        VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
        VK_LAYER_SETTINGS_PATH="$SETTINGS"

    got=$(grep -c 'swapchain recreated' "$SCRATCH/mock_event.txt")
    if [ "${got:-0}" -eq 4 ]; then
        ok "swapchain rebuilt 4 times"
    else
        bad "expected 4 swapchain rebuilds, saw ${got:-0}"
    fi

    seen=$(grep -c 'vkCreateSwapchainKHR' "$LAYER_LOG" 2>/dev/null)
    if [ "${seen:-0}" -ge 5 ]; then
        ok "layer re-initialised on every rebuild ($seen creations)"
    else
        bad "layer only saw ${seen:-0} swapchain creations, expected 5"
    fi

    if grep -q 'Khronos Validation Layer Active' "$SCRATCH/mock_event.txt"; then
        errs=$(grep -cE 'Validation Error|VUID-' "$SCRATCH/mock_event.txt")
        if [ "${errs:-0}" -eq 0 ]; then
            ok "no validation errors across repeated swapchain rebuilds"
        else
            bad "$errs validation error line(s) during rebuild"
            grep -E 'Validation Error|VUID-' "$SCRATCH/mock_event.txt" | head -10
        fi
    else
        bad "validation layer did not load — rebuild result proves nothing"
    fi
fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] || exit 1
