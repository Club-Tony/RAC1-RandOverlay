#!/usr/bin/env bash
# Desktop-integration tests for the RandOverlay implicit Vulkan layer.
#
# These cover the two remaining risks that are about the DESKTOP rather than the
# GPU, so unlike the certification runbook they run fine in a plain VM
# (Hyper-V/VirtualBox) on software rendering:
#
#   flatpak   — can a sandboxed RPCS3/PCSX2 see the layer and the Archipelago
#               logs at all? This is the likeliest real-world failure, because
#               Flatpak is how most people install these emulators on Linux.
#   mangohud  — does the layer coexist with another implicit layer that also
#               hooks vkQueuePresentKHR, or do they fight over present?
#
#   ./run_desktop_integration_tests.sh              both
#   ./run_desktop_integration_tests.sh flatpak
#   ./run_desktop_integration_tests.sh mangohud
#   ./run_desktop_integration_tests.sh flatpak --apply-override
#
# By default the Flatpak check only DIAGNOSES and prints the override command it
# would run. Pass --apply-override to actually change your flatpak permissions.
set -uo pipefail

MODE="all"
APPLY_OVERRIDE=0
for arg in "$@"; do
    case "$arg" in
        flatpak|mangohud|all) MODE="$arg" ;;
        --apply-override)     APPLY_OVERRIDE=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd -- "$HERE/.." && pwd)"
BUILD="${RANDOVERLAY_BUILD_DIR:-$PROJ/build/linux}"
MOCK="$BUILD/rpcs3"
SCRATCH="${RANDOVERLAY_SCRATCH:-${TMPDIR:-/tmp}/randoverlay-desktop}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
MANIFEST_DIR="$DATA_HOME/vulkan/implicit_layer.d"

pass=0; fail=0; skip=0
if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; YEL=""; DIM=""; RESET=""; fi
ok()   { pass=$((pass+1)); printf '  %s[PASS]%s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { fail=$((fail+1)); printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$1"; }
skp()  { skip=$((skip+1)); printf '  %s[SKIP]%s %s\n' "$YEL" "$RESET" "$1"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }

echo "=== RandOverlay desktop integration (mode: $MODE) ==="

[ -f "$MANIFEST_DIR/RandOverlay_layer.json" ] || {
    echo "Layer not registered. Run install_layer.sh first." >&2; exit 1; }

# ── Flatpak ───────────────────────────────────────────────────────────────────
# A Flatpak app cannot see ~/.local/share by default. Both the layer manifest
# and the Archipelago log directory have to be granted explicitly, and the
# layer's own library path (which the manifest points at with an absolute path)
# has to resolve inside the sandbox too.
if [ "$MODE" = "all" ] || [ "$MODE" = "flatpak" ]; then
    echo
    echo "[flatpak]"

    if ! command -v flatpak >/dev/null 2>&1; then
        skp "flatpak not installed — nothing to check"
    else
        found_any=0
        for app in org.rpcs3.RPCS3 net.pcsx2.PCSX2; do
            flatpak info "$app" >/dev/null 2>&1 || continue
            found_any=1
            echo "  --- $app ---"

            # Definitive check when the runtime has vulkaninfo; otherwise fall
            # back to whether the manifest file is even visible in the sandbox.
            method="vulkaninfo"
            out=$(flatpak run --command=vulkaninfo "$app" 2>/dev/null) || out=""
            if [ -z "$out" ]; then
                method="file visibility"
                out=$(flatpak run --command=ls "$app" "$MANIFEST_DIR" 2>/dev/null) || out=""
            fi
            note "probe method: $method"

            if echo "$out" | grep -qi 'randoverlay'; then
                ok "$app can see the layer"
            else
                bad "$app cannot see the layer (expected without an override)"
                cmd="flatpak override --user --filesystem=xdg-data/vulkan:ro --filesystem=xdg-data/RandOverlay:ro $app"
                if [ "$APPLY_OVERRIDE" = "1" ]; then
                    note "applying: $cmd"
                    $cmd && ok "override applied — re-run to confirm" \
                         || bad "override command failed"
                else
                    note "fix: $cmd"
                    note "(re-run with --apply-override to apply it here)"
                fi
            fi

            # Even with the layer visible, the overlay stays blank unless the
            # sandbox can also read the Archipelago logs.
            logdir=$(sed -n 's/^[[:space:]]*LogDirLinux[[:space:]]*=[[:space:]]*//p' \
                     "$DATA_HOME/RandOverlay/RandOverlay.ini" 2>/dev/null | tail -1)
            [ -z "$logdir" ] && logdir="$HOME/.local/share/Archipelago/logs"
            if flatpak run --command=ls "$app" "$logdir" >/dev/null 2>&1; then
                ok "$app can read the Archipelago log dir"
            else
                bad "$app cannot read $logdir"
                note "fix: flatpak override --user --filesystem=\"$logdir:ro\" $app"
            fi
        done
        [ "$found_any" = "0" ] && skp "neither RPCS3 nor PCSX2 is installed as a Flatpak"
    fi
fi

# ── MangoHud coexistence ──────────────────────────────────────────────────────
# MangoHud is also a GLOBAL implicit layer that hooks vkQueuePresentKHR. Two
# layers wrapping the same call is exactly the case most likely to break, and
# it is common — plenty of people run MangoHud permanently.
if [ "$MODE" = "all" ] || [ "$MODE" = "mangohud" ]; then
    echo
    echo "[mangohud coexistence]"

    if ! command -v mangohud >/dev/null 2>&1 && \
       ! ls /usr/share/vulkan/implicit_layer.d/*angoHud*.json >/dev/null 2>&1; then
        skp "mangohud not installed (sudo apt install mangohud)"
    elif [ ! -x "$MOCK" ]; then
        bad "mock host missing at $MOCK — build it first"
    elif [ -z "${DISPLAY:-}" ]; then
        skp "no DISPLAY — run inside a desktop session"
    else
        icd=$(find /usr/share/vulkan/icd.d /usr/local/share/vulkan/icd.d \
                   -name 'lvp_icd*.json' 2>/dev/null | head -1)
        [ -n "$icd" ] && export VK_ICD_FILENAMES="$icd"

        rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/logs"
        INI="$SCRATCH/RandOverlay.ini"
        cat > "$INI" <<EOF
[General]
ActivePreset=RAC1
EnabledPresets=RAC1
LogDirLinux=$SCRATCH/logs
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
        cat > "$SCRATCH/vk_layer_settings.txt" <<EOF
khronos_validation.debug_action = VK_DBG_LAYER_ACTION_LOG_MSG
khronos_validation.log_filename = stdout
khronos_validation.report_flags = error,warn,info
EOF
        LOGF="$SCRATCH/logs/Client_desktop.txt"
        echo "seed" > "$LOGF"

        LAYER_SO=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' \
                   "$MANIFEST_DIR/RandOverlay_layer.json")
        LAYER_LOG="$(dirname "$LAYER_SO")/layer_debug.log"
        rm -f "$LAYER_LOG"

        ( sleep 2; echo "[Client at 12:00:00]: Ratchet found their Hydrodisplacer (RAC1)" >> "$LOGF" ) &

        MANGOHUD=1 \
        RANDOVERLAY_INI="$INI" RANDOVERLAY_NO_PROMPT=1 \
        VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
        VK_LAYER_SETTINGS_PATH="$SCRATCH/vk_layer_settings.txt" \
        MOCK_SECONDS=8 MOCK_STATIC_FRAME=1 MOCK_READBACK=1 \
        MOCK_READBACK_PPM="$SCRATCH/frame.ppm" \
        "$MOCK" > "$SCRATCH/mangohud.txt" 2>&1
        wait

        if grep -q 'process=rpcs3.*disabled=0' "$LAYER_LOG" 2>/dev/null; then
            ok "RandOverlay still activates with MangoHud present"
        else
            bad "RandOverlay did not activate alongside MangoHud"
        fi

        diff=$(sed -n 's/.*\[mock-readback\].*differing=\([0-9]*\).*/\1/p' \
               "$SCRATCH/mangohud.txt" | tail -1)
        if [ -n "$diff" ] && [ "$diff" -gt 2000 ]; then
            ok "overlay still reaches the presented frame (differing=$diff)"
            note "inspect $SCRATCH/frame.ppm to confirm both overlays drew"
        else
            bad "overlay missing from the frame with MangoHud active (differing=${diff:-none})"
        fi

        if grep -q 'Khronos Validation Layer Active' "$SCRATCH/mangohud.txt"; then
            errs=$(grep -cE 'Validation Error|VUID-' "$SCRATCH/mangohud.txt")
            if [ "${errs:-0}" -eq 0 ]; then
                ok "no validation errors with two present-hooking layers"
            else
                bad "$errs validation error line(s) — layers may be conflicting"
                grep -E 'Validation Error|VUID-' "$SCRATCH/mangohud.txt" | head -10
            fi
        else
            skp "validation layer did not load — error count not meaningful"
        fi
    fi
fi

echo
echo "=== $pass passed, $fail failed, $skip skipped ==="
[ "$fail" -eq 0 ] || exit 1
