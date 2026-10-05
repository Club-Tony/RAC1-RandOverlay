#pragma once
/*
 * "Is Archipelago running?" check + launch prompt for the RandOverlay layer.
 *
 * Parity with RandOverlay.ahk's startup check: the overlay is useless without
 * an Archipelago client writing logs, so when the overlay activates and no
 * Archipelago process is found, offer to start the launcher (Yes/No prompt).
 *
 * The prompt is Windows-only and shown at most once per emulator process. On
 * Linux the caller just logs the condition — see promptIfNotRunning() for why.
 * Suppress the prompt entirely with RANDOVERLAY_NO_PROMPT=1 (used by tests).
 */
#include "platform.h"
#include <string>

#ifdef _WIN32
  #include <windows.h>
  #include <shellapi.h>
  #include <cstdio>
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
    HMODULE     self;            // reference that keeps this DLL mapped
};

// True the first time it is called in this process, false ever after.
//
// A static flag is not enough: the Vulkan loader unloads the layer whenever the
// emulator destroys its instance, and RPCS3 does that on every boot — including
// the exitspawn restart the RAC1 multiplayer loader (BORD00001) performs within
// a second of booting, which used to stack two prompts. A named mutex keyed by
// PID outlives the unload; its handle is deliberately never closed, so it lasts
// exactly as long as the emulator process.
inline bool claimPromptForProcess() {
    char name[64];
    snprintf(name, sizeof(name), "Local\\RandOverlay.Prompted.%lu",
             (unsigned long)GetCurrentProcessId());
    HANDLE h = CreateMutexA(nullptr, FALSE, name);
    if (!h) return true;  // cannot tell; err on the side of telling the user
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(h);
        return false;
    }
    return true;
}

inline DWORD WINAPI promptThread(LPVOID param) {
    PromptContext* ctx = (PromptContext*)param;
    // Three-way choice. Game clients are apworld-provided launcher components,
    // so the layer cannot reliably enumerate what's installed — the launcher UI
    // is the authoritative picker. Yes hands the launcher the preset's client
    // name, and the launcher starts it only if an installed apworld registers
    // it; otherwise it just opens. RAC1 is that case today: rac1.apworld
    // registers no launcher client, because the game reaches Archipelago
    // through Lawrence. So the wording promises an attempt, not a client.
    std::string msg =
        "Archipelago is not running.\n\n"
        "The overlay reads Archipelago client logs, so a client must be "
        "running for messages to appear.\n\n"
        "Yes  -  open the Archipelago Launcher and try to start the " +
        ctx->presetName + " client:\n"
        "           \"" + ctx->clientComponent + "\"\n"
        "           (if no installed apworld provides it, only the launcher opens)\n\n"
        "No  -  open the Archipelago Launcher to pick a client yourself\n"
        "           (Text Client / RAC1 / RAC2 / RAC3 / anything else installed)\n\n"
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
    HMODULE self = ctx->self;
    delete ctx;
    // The dialog can outlive the instance that raised it (an exitspawn reboot
    // unloads the layer mid-prompt), so the thread holds its own reference to
    // the DLL and drops it only on the way out.
    if (self) FreeLibraryAndExitThread(self, 0);
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
    if (!claimPromptForProcess()) return false;
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                       reinterpret_cast<LPCSTR>(&promptThread), &self);
    PromptContext* ctx = new PromptContext{launcherExe, presetName, clientComponent, self};
    HANDLE t = CreateThread(nullptr, 0, promptThread, ctx, 0, nullptr);
    if (t) CloseHandle(t);
    else {
        delete ctx;
        if (self) FreeLibrary(self);
    }
#else
    (void)launcherExe; (void)presetName; (void)clientComponent;
#endif
    return false;
}

} // namespace roarch
