#!/usr/bin/env bash
# Register (or remove) the RandOverlay implicit Vulkan layer for the current
# user. The Linux counterpart of install_layer.bat — where Windows needs a
# registry value under HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers, Linux just
# wants a manifest in an implicit_layer.d directory.
#
#   ./install_layer.sh              install from ./build
#   ./install_layer.sh --build-dir out
#   ./install_layer.sh --uninstall
#   ./install_layer.sh --status
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ACTION="install"

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) ACTION="uninstall" ;;
        --status)    ACTION="status" ;;
        --build-dir) BUILD_DIR="$2"; shift ;;
        -h|--help)   sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
INSTALL_DIR="${DATA_HOME}/RandOverlay"
MANIFEST_DIR="${DATA_HOME}/vulkan/implicit_layer.d"
MANIFEST="${MANIFEST_DIR}/RandOverlay_layer.json"
LIB_NAME="libVkLayer_RandOverlay.so"

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
err()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1" >&2; }

printf '%s=== RandOverlay Vulkan layer ===%s\n\n' "$BOLD" "$RESET"

case "$ACTION" in
status)
    if [ -f "$MANIFEST" ]; then
        ok "Registered: $MANIFEST"
        lib=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$MANIFEST")
        if [ -f "$lib" ]; then ok "Library:    $lib"
        else err "Library MISSING: $lib"; fi
        if [ -f "${INSTALL_DIR}/RandOverlay.ini" ]; then
            ok "Config:     ${INSTALL_DIR}/RandOverlay.ini"
        else
            warn "No config installed — the layer will run on built-in defaults."
        fi
    else
        warn "Not registered (no $MANIFEST)"
    fi
    if [ -n "${VK_ADD_IMPLICIT_LAYER_PATH:-}" ]; then
        err "VK_ADD_IMPLICIT_LAYER_PATH is set — see the warning below."
    fi
    command -v vulkaninfo >/dev/null 2>&1 && \
        printf '\n%sLoader sees:%s\n' "$DIM" "$RESET" && \
        (vulkaninfo --summary 2>/dev/null | grep -i randoverlay || echo "  (layer not listed)")
    exit 0
    ;;

uninstall)
    removed=0
    if [ -f "$MANIFEST" ]; then rm -f "$MANIFEST"; ok "Removed $MANIFEST"; removed=1; fi
    if [ -d "$INSTALL_DIR" ]; then rm -rf "$INSTALL_DIR"; ok "Removed $INSTALL_DIR"; removed=1; fi
    [ "$removed" -eq 0 ] && warn "Nothing to remove."
    exit 0
    ;;
esac

# ── install ───────────────────────────────────────────────────────────────────
SRC_LIB="${BUILD_DIR}/${LIB_NAME}"
if [ ! -f "$SRC_LIB" ]; then
    err "Layer not built: $SRC_LIB"
    echo
    echo "  Build it first:"
    echo "    cmake -S \"$SCRIPT_DIR\" -B \"$BUILD_DIR\" -DCMAKE_BUILD_TYPE=Release"
    echo "    cmake --build \"$BUILD_DIR\" -j"
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$MANIFEST_DIR"
install -m 0755 "$SRC_LIB" "${INSTALL_DIR}/${LIB_NAME}"
ok "Installed ${INSTALL_DIR}/${LIB_NAME}"

# The layer resolves RandOverlay.ini relative to its own directory, so install a
# copy alongside it. Without this the installed layer silently runs on built-in
# defaults — including a Windows log path and fonts that do not exist here.
# An existing ini is never overwritten, so re-running keeps your settings.
SRC_INI="${SCRIPT_DIR}/../RandOverlay.ini"
if [ -f "${INSTALL_DIR}/RandOverlay.ini" ]; then
    ok "Kept existing ${INSTALL_DIR}/RandOverlay.ini"
elif [ -f "$SRC_INI" ]; then
    install -m 0644 "$SRC_INI" "${INSTALL_DIR}/RandOverlay.ini"
    ok "Installed ${INSTALL_DIR}/RandOverlay.ini"
else
    warn "No RandOverlay.ini found at $SRC_INI — the layer will use defaults."
fi

# Write the manifest with an absolute library_path so the loader resolves it
# regardless of which directory it scanned the manifest from.
TEMPLATE="${SCRIPT_DIR}/RandOverlay_layer.json.in"
if [ ! -f "$TEMPLATE" ]; then err "Missing $TEMPLATE"; exit 1; fi
sed "s|@RANDOVERLAY_LIBRARY_PATH@|${INSTALL_DIR}/${LIB_NAME}|" "$TEMPLATE" > "$MANIFEST"
ok "Registered $MANIFEST"

echo
printf '%sNotes%s\n' "$BOLD" "$RESET"
echo "  • Disable without uninstalling:  DISABLE_RANDOVERLAY=1 <emulator>"
echo "  • Check registration:            $0 --status"

if [ -n "${VK_ADD_IMPLICIT_LAYER_PATH:-}" ]; then
    echo
    err "VK_ADD_IMPLICIT_LAYER_PATH is set in this environment."
    echo "    The layer is now discoverable through a standard search path AND"
    echo "    through that variable. Two discovery routes for one layer make the"
    echo "    loader load it twice and crash the host. Unset it before playing."
fi

# Flatpak is the dominant way RPCS3/PCSX2 are installed on Linux, and the
# sandbox cannot see ~/.local/share by default.
if command -v flatpak >/dev/null 2>&1; then
    for app in org.rpcs3.RPCS3 net.pcsx2.PCSX2; do
        if flatpak info "$app" >/dev/null 2>&1; then
            echo
            warn "$app is installed as a Flatpak and cannot see this layer yet."
            echo "    Grant it access to the layer and your Archipelago logs:"
            echo "      flatpak override --user --filesystem=xdg-data/vulkan:ro \\"
            echo "                              --filesystem=xdg-data/RandOverlay:ro $app"
        fi
    done
fi

echo
ok "Done. Start the emulator with its Vulkan renderer selected."
