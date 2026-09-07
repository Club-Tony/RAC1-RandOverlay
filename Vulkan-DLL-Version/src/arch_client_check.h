#pragma once
/*
 * "Is Archipelago running?" check + launch prompt for the RandOverlay layer.
 *
 * Parity with RandOverlay.ahk's startup check: the overlay is useless without
 * an Archipelago client writing logs, so when the overlay activates and no
 * Archipelago process is found, offer to start the launcher (Yes/No prompt).
 *
 * The prompt is Windows-only. On Linux the caller just logs the condition —
 * see promptIfNotRunning() for why. Suppress the prompt entirely with
 * RANDOVERLAY_NO_PROMPT=1 (used by tests).
 */
#include "platform.h"
#include <string>

#ifdef _WIN32
  #include <windows.h>
  #include <shellapi.h>
#endif

namespace roarch {

// True if any process image name starts with "Archipelago" (launcher, text
// client, game clients — all ship as Archipelago*).
inline bool isArchipelagoRunning() {
    return roplat::processRunningWithPrefix("Archipelago");
}

#ifdef _WIN32

struct PromptContext {
    std::string launcherExe;
    std::string presetName;      // e.g. "RAC1"
    std::string clientComponent; // e.g. "Ratchet & Clank 2 Client"
};

inline DWORD WINAPI promptThread(LPVOID param) {
    PromptContext* ctx = (PromptContext*)param;
    // Three-way choice. Game clients are apworld-provided launcher components,
    // so the layer cannot reliably enumerate what's installed — the launcher UI
    // is the authoritative picker. Yes = the active preset's client directly.
    std::string msg =
        "Archipelago is not running.\n\n"
        "The overlay reads Archipelago client logs, so a client must be "
        "running for messages to appear.\n\n"
        "Yes  -  launch the " + ctx->presetName + " client:\n"
        "           \"" + ctx->clientComponent + "\"\n\n"
        "No  -  open the Archipelago Launcher to pick a client yourself\n"
        "           (RAC1 / RAC2 / RAC3 / anything else installed)\n\n"
        "Cancel  -  do nothing";
    int rc = MessageBoxA(nullptr, msg.c_str(), "Archipelago Overlay",
        MB_YESNOCANCEL | MB_ICONQUESTION | MB_TOPMOST | MB_SETFOREGROUND);
    if (!ctx->launcherExe.empty()) {
        if (rc == IDYES) {
            std::string params = "\"" + ctx->clientComponent + "\"";
            ShellExecuteA(nullptr, "open", ctx->launcherExe.c_str(), params.c_str(), nullptr, SW_SHOWNORMAL);
        } else if (rc == IDNO) {
            ShellExecuteA(nullptr, "open", ctx->launcherExe.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        }
    }
    delete ctx;
    return 0;
}

#endif // _WIN32

// Returns true if Archipelago is already running.
//
// When it is not, Windows offers the launcher prompt on a background thread so
// the game's render thread is never blocked. Linux deliberately does not
// prompt: a modal dialog spawned from inside vkQueuePresentKHR has no reliable
// always-on-top under a Wayland compositor, and can wedge a fullscreen game
// behind an unreachable window. The caller logs the condition instead.
inline bool promptIfNotRunning(const std::string& launcherExe,
                               const std::string& presetName,
                               const std::string& clientComponent) {
    if (isArchipelagoRunning()) return true;
    if (roplat::envEquals("RANDOVERLAY_NO_PROMPT", "1")) return false;

#ifdef _WIN32
    PromptContext* ctx = new PromptContext{launcherExe, presetName, clientComponent};
    HANDLE t = CreateThread(nullptr, 0, promptThread, ctx, 0, nullptr);
    if (t) CloseHandle(t);
    else   delete ctx;
#else
    (void)launcherExe; (void)presetName; (void)clientComponent;
#endif
    return false;
}

} // namespace roarch
