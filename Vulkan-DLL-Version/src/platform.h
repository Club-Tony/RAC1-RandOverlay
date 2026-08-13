#pragma once
/*
 * Platform abstraction for the RandOverlay Vulkan layer.
 *
 * Everything the layer needs that standard C++ cannot express portably lives
 * here, and nowhere else. Keeping this list short is deliberate: the Vulkan
 * dispatch chain, ImGui rendering, config parsing and log tailing are all
 * OS-agnostic, so a new platform only has to supply the three functions in the
 * "genuinely platform-specific" block below.
 *
 * Timing, environment and filesystem work is done with std::chrono /
 * std::getenv / std::filesystem rather than Win32 equivalents, so those call
 * sites need no #ifdef at all.
 */
#include <string>
#include <vector>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <filesystem>

#ifdef _WIN32
  #include <windows.h>
  #include <tlhelp32.h>
  #include <shellapi.h>
#else
  #include <dlfcn.h>
  #include <unistd.h>
  #include <limits.h>
  #include <cstring>
  #include <fstream>
#endif

namespace roplat {

// ── Portable (standard C++), centralised so call sites have one home ──────────

// Milliseconds from an unspecified monotonic epoch. Replaces GetTickCount64;
// steady_clock is monotonic on both platforms and immune to wall-clock changes.
inline uint64_t monotonicMs() {
    using namespace std::chrono;
    return (uint64_t)duration_cast<milliseconds>(
        steady_clock::now().time_since_epoch()).count();
}

inline bool getEnv(const char* name, std::string& out) {
    const char* v = std::getenv(name);
    if (!v || !*v) return false;
    out = v;
    return true;
}

inline bool envEquals(const char* name, const char* value) {
    std::string v;
    return getEnv(name, v) && v == value;
}

inline bool fileExists(const std::string& p) {
    if (p.empty()) return false;
    std::error_code ec;
    return std::filesystem::is_regular_file(p, ec);
}

inline bool dirExists(const std::string& p) {
    if (p.empty()) return false;
    std::error_code ec;
    return std::filesystem::is_directory(p, ec);
}

// Lexically normalised absolute path, or "" if it cannot be formed.
inline std::string absPath(const std::string& p) {
    if (p.empty()) return "";
    std::error_code ec;
    std::filesystem::path abs = std::filesystem::absolute(p, ec);
    if (ec) return "";
    return abs.lexically_normal().string();
}

inline std::string baseName(const std::string& p) {
    return std::filesystem::path(p).filename().string();
}

inline std::string joinPath(const std::string& dir, const std::string& leaf) {
    if (dir.empty()) return leaf;
    return (std::filesystem::path(dir) / leaf).string();
}

inline std::string toLower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

// Case-insensitive "does `s` start with `prefix`".
inline bool startsWithNoCase(const std::string& s, const char* prefix) {
    size_t n = std::strlen(prefix);
    if (s.size() < n) return false;
    for (size_t i = 0; i < n; i++)
        if (std::tolower((unsigned char)s[i]) != std::tolower((unsigned char)prefix[i]))
            return false;
    return true;
}

// The user's home directory, or "" if it cannot be determined.
inline std::string homeDir() {
    std::string h;
#ifdef _WIN32
    if (getEnv("USERPROFILE", h)) return h;
    std::string drive, path;
    if (getEnv("HOMEDRIVE", drive) && getEnv("HOMEPATH", path)) return drive + path;
#else
    if (getEnv("HOME", h)) return h;
#endif
    return "";
}

// Where the Archipelago client writes its logs, by convention per OS.
//
// Windows has one well-known location. Linux has no equivalent of ProgramData:
// the official release is an extracted tarball or AppImage that logs into its
// own directory, so probe the plausible spots and return the first that exists.
// Users on any layout can always override this with LogDir= in RandOverlay.ini.
inline std::string defaultArchipelagoLogDir() {
#ifdef _WIN32
    return "C:\\ProgramData\\Archipelago\\logs";
#else
    std::string xdg, home = homeDir();
    std::vector<std::string> candidates;
    if (getEnv("XDG_DATA_HOME", xdg))
        candidates.push_back(joinPath(xdg, "Archipelago/logs"));
    if (!home.empty()) {
        candidates.push_back(joinPath(home, ".local/share/Archipelago/logs"));
        candidates.push_back(joinPath(home, "Archipelago/logs"));
        candidates.push_back(joinPath(home, "Games/Archipelago/logs"));
    }
    for (const std::string& c : candidates)
        if (dirExists(c)) return c;
    return candidates.empty() ? std::string() : candidates.front();
#endif
}

// The Archipelago launcher binary. Only used by the Windows "client isn't
// running" prompt; on Linux it is reported for diagnostics but never executed.
inline std::string defaultArchipelagoLauncher() {
#ifdef _WIN32
    return "C:\\ProgramData\\Archipelago\\ArchipelagoLauncher.exe";
#else
    std::string logs = defaultArchipelagoLogDir();
    if (logs.empty()) return "";
    // logs live at <install>/logs, so the launcher sits one level up.
    std::filesystem::path parent = std::filesystem::path(logs).parent_path();
    return (parent / "ArchipelagoLauncher").string();
#endif
}

// ── Genuinely platform-specific ───────────────────────────────────────────────

// Full path of the running process image (the emulator, when we are a layer).
inline std::string selfExePath();

// Directory containing the shared library this code is compiled into. Used to
// locate RandOverlay.ini and to place layer_debug.log next to the layer.
inline std::string moduleDir();

// True if any running process's image name starts with `prefix` (no case).
inline bool processRunningWithPrefix(const char* prefix);

#ifdef _WIN32

inline std::string selfExePath() {
    char path[MAX_PATH] = {0};
    GetModuleFileNameA(nullptr, path, MAX_PATH); // NULL => current process image
    return std::string(path);
}

inline std::string moduleDir() {
    HMODULE hm = nullptr;
    static int marker = 0;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCSTR)&marker, &hm);
    char path[MAX_PATH] = {0};
    GetModuleFileNameA(hm, path, MAX_PATH);
    std::string p(path);
    size_t slash = p.find_last_of("\\/");
    return (slash == std::string::npos) ? std::string() : p.substr(0, slash);
}

inline bool processRunningWithPrefix(const char* prefix) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;

    bool found = false;
    PROCESSENTRY32 pe;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (startsWithNoCase(pe.szExeFile, prefix)) { found = true; break; }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

#else // ── POSIX ──────────────────────────────────────────────────────────────

inline std::string selfExePath() {
    // Resolves through AppImage mounts too: an AppImage'd RPCS3 has argv[0] of
    // "AppRun" but /proc/self/exe points at the real binary inside the mount,
    // whose basename is still "rpcs3".
    char buf[PATH_MAX] = {0};
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) { buf[n] = '\0'; return std::string(buf); }

    // Fallback for systems without /proc: the kernel-supplied argv[0].
    std::string v;
    if (getEnv("_", v)) return v;
    return "";
}

inline std::string moduleDir() {
    // dladdr maps any address back to the shared object containing it, which is
    // the .so this header was compiled into — the analogue of
    // GetModuleHandleEx(FROM_ADDRESS).
    static int marker = 0;
    Dl_info info;
    if (dladdr(&marker, &info) && info.dli_fname && *info.dli_fname) {
        std::string p(info.dli_fname);
        // dli_fname can be relative to the cwd of the loading process.
        std::string abs = absPath(p);
        if (!abs.empty()) p = abs;
        size_t slash = p.find_last_of('/');
        if (slash != std::string::npos) return p.substr(0, slash);
    }
    return "";
}

inline bool processRunningWithPrefix(const char* prefix) {
    std::error_code ec;
    std::filesystem::directory_iterator it("/proc", ec);
    if (ec) return false;

    for (const auto& entry : it) {
        const std::string name = entry.path().filename().string();
        if (name.empty() || !std::isdigit((unsigned char)name[0])) continue;

        // /proc/<pid>/comm is the thread name, truncated to 15 chars. That is
        // long enough for "Archipelago" (11), and it is what a native launcher
        // build reports.
        std::ifstream comm(entry.path() / "comm");
        std::string line;
        if (comm && std::getline(comm, line) && startsWithNoCase(line, prefix))
            return true;

        // Archipelago also ships as a Python app, where comm is "python3" and
        // the real identity is argv[0]. cmdline is NUL-separated; the first
        // field is the executable.
        std::ifstream cmd(entry.path() / "cmdline", std::ios::binary);
        if (!cmd) continue;
        std::string argv0;
        std::getline(cmd, argv0, '\0');
        if (argv0.empty()) continue;
        if (startsWithNoCase(baseName(argv0), prefix)) return true;
    }
    return false;
}

#endif // _WIN32

} // namespace roplat
