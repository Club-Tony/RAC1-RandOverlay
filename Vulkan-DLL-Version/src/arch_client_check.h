#pragma once
/*
 * "Is Archipelago running?" check + launch prompt for the RandOverlay layer.
 *
 * Parity with RandOverlay.ahk's startup check: the overlay is useless without
 * an Archipelago client writing logs, so when the overlay activates and no
 * Archipelago process is found, offer to start the launcher (Yes/No prompt).
 *
 * The prompt runs on its own thread so the game's render thread is never
 * blocked. Suppress entirely with RANDOVERLAY_NO_PROMPT=1 (used by tests).
 */
#include <windows.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <string>

namespace roarch {

// True if any process image name starts with "Archipelago" (launcher, text
// client, game clients — all ship as Archipelago*.exe).
inline bool isArchipelagoRunning() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;

    bool found = false;
    PROCESSENTRY32 pe;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (_strnicmp(pe.szExeFile, "Archipelago", 11) == 0) { found = true; break; }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

struct PromptContext {
    std::string launcherExe;
    std::string presetName;      // e.g. "RAC1"
    std::string clientComponent; // e.g. "Ratchet & Clank 2 Client"
};

inline DWORD WINAPI promptThread(LPVOID param) {
    PromptContext* ctx = (PromptContext*)param;
    // Three-way choice. Game clients are apworld-provided launcher components,
    // so the DLL cannot reliably enumerate what's installed — the launcher UI
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

// Fire-and-forget: if Archipelago isn't running, ask (once) on a background
// thread which client to start. Never blocks the caller.
inline void promptIfNotRunning(const std::string& launcherExe,
                               const std::string& presetName,
                               const std::string& clientComponent) {
    char env[8] = {0};
    if (GetEnvironmentVariableA("RANDOVERLAY_NO_PROMPT", env, sizeof(env)) > 0 &&
        env[0] == '1')
        return;
    if (isArchipelagoRunning()) return;

    PromptContext* ctx = new PromptContext{launcherExe, presetName, clientComponent};
    HANDLE t = CreateThread(nullptr, 0, promptThread, ctx, 0, nullptr);
    if (t) CloseHandle(t);
    else   delete ctx;
}

} // namespace roarch
