#pragma once
/*
 * RandOverlay shared config reader.
 *
 * Parses the repo-root RandOverlay.ini (the same file the AHK and PS+WPF
 * runtimes read) so all three runtimes stay visually consistent. Header-only,
 * no third-party deps. Falls back to RAC1 defaults if the ini is missing or a
 * value is malformed — never throws out to the caller.
 */
#include "platform.h"
#include <string>
#include <map>
#include <fstream>
#include <algorithm>
#include <cctype>

// Font defaults differ by platform: the R&C-style families the AHK and PS+WPF
// runtimes rely on are Windows-installed and simply do not exist on Linux, so
// picking them there would silently drop every user to ImGui's built-in bitmap
// font. Ship families that are actually present instead, and let anyone with
// the real fonts point at them with FontFile= or FontFamily=.
#ifdef _WIN32
  #define RANDOVERLAY_DEFAULT_FONT          "HandelGothic BT"  // parity: AHK/PS
  #define RANDOVERLAY_DEFAULT_FONT_FALLBACK "Bahnschrift"      // ships with Win10/11
#else
  #define RANDOVERLAY_DEFAULT_FONT          "DejaVu Sans"      // near-universal on Linux
  #define RANDOVERLAY_DEFAULT_FONT_FALLBACK "Liberation Sans"
#endif

struct RandOverlayConfig {
    std::string activePreset  = "RAC1";
    std::string enabledPresets = "RAC1";
    std::string logDir        = roplat::defaultArchipelagoLogDir();
    std::string launcherExe   = roplat::defaultArchipelagoLauncher();
    std::string emulatorProcs = "rpcs3.exe";
    std::string fontFamily    = RANDOVERLAY_DEFAULT_FONT;
    std::string fontFallback  = RANDOVERLAY_DEFAULT_FONT_FALLBACK;
    // Absolute path to a .ttf/.otf, bypassing family-name resolution entirely.
    // The escape hatch for Linux, where there is no font registry to search and
    // fontconfig will happily substitute something unintended.
    std::string fontFile;
    // Archipelago Launcher component to start for this preset (launcher arg).
    // Defaults are derived from ActivePreset in load(); override per preset
    // with ClientComponent= in RandOverlay.ini.
    std::string clientComponent = "Text Client";
    float overlayColor[3]     = {0.502f, 0.627f, 0.816f}; // #80A0D0
    float bgColor[3]          = {0.118f, 0.118f, 0.118f}; // #1E1E1E
    float bgAlpha             = 0.80f;                    // background panel opacity (parity: PS+WPF BgOpacity 0.80)
    float verticalPercent     = 0.17f;                    // 0=top .. 1=bottom
    int   fontSize            = 48;                        // 1080p px baseline (VulkanFontSize)
    int   displayMs           = 5000;                     // message hold time
    int   pollMs              = 1500;                     // log poll cadence (parity: AHK/PS PollMs)
    int   fadeInMs            = 300;                      // fade-in duration (parity: FadeInMs)
    int   fadeOutMs           = 500;                      // fade-out duration (parity: FadeOutMs)
    std::string iniPathUsed;                              // for diagnostics
    bool  loaded              = false;

    void load(const std::string& presetOverride = "");
};

namespace rocfg_detail {

inline std::string trim(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

inline bool parseHexColor(const std::string& in, float out[3]) {
    std::string s = trim(in);
    if (!s.empty() && s[0] == '#') s = s.substr(1);
    if (s.size() != 6) return false;
    auto hx = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    int v[6];
    for (int i = 0; i < 6; i++) { v[i] = hx(s[i]); if (v[i] < 0) return false; }
    out[0] = (v[0] * 16 + v[1]) / 255.0f;
    out[1] = (v[2] * 16 + v[3]) / 255.0f;
    out[2] = (v[4] * 16 + v[5]) / 255.0f;
    return true;
}

// True for "C:\...", "\\server\share", or anything containing a backslash.
// Used to reject Windows paths carried in the shared ini when running on Linux.
inline bool looksLikeWindowsPath(const std::string& p) {
    if (p.size() >= 2 && std::isalpha((unsigned char)p[0]) && p[1] == ':') return true;
    return p.find('\\') != std::string::npos;
}

inline std::string resolveIniPath() {
    // 1) explicit override
    std::string env;
    if (roplat::getEnv("RANDOVERLAY_INI", env) && roplat::fileExists(env))
        return env;

    // 2) walk up from the shared-library directory. The built layer normally
    //    lives in <repo>/Vulkan-DLL-Version/build/ -> ini is at
    //    <repo>/RandOverlay.ini. Forward slashes are accepted on both platforms.
    std::string dir = roplat::moduleDir();
    if (dir.empty()) return "";
    const char* rels[] = { "../../RandOverlay.ini",
                           "../RandOverlay.ini",
                           "RandOverlay.ini" };
    for (const char* rel : rels) {
        std::string cand = roplat::absPath(roplat::joinPath(dir, rel));
        if (roplat::fileExists(cand)) return cand;
    }
    return "";
}

} // namespace rocfg_detail

inline void RandOverlayConfig::load(const std::string& presetOverride) {
    using namespace rocfg_detail;
    std::string ini = resolveIniPath();
    iniPathUsed = ini;
    if (ini.empty()) return; // keep defaults

    std::ifstream f(ini);
    if (!f.is_open()) return;

    std::map<std::string, std::map<std::string, std::string>> sections;
    std::string line, section;
    while (std::getline(f, line)) {
        std::string t = trim(line);
        if (t.empty() || t[0] == ';' || t[0] == '#') continue;
        if (t.front() == '[' && t.back() == ']') { section = t.substr(1, t.size() - 2); continue; }
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        sections[section][trim(t.substr(0, eq))] = trim(t.substr(eq + 1));
    }

    auto get = [&](const std::string& sec, const std::string& key, std::string& out) -> bool {
        auto si = sections.find(sec);
        if (si == sections.end()) return false;
        auto ki = si->second.find(key);
        if (ki == si->second.end()) return false;
        out = ki->second;
        return true;
    };

    std::string tmp;
    if (get("General", "ActivePreset", tmp) && !tmp.empty()) activePreset = tmp;
    if (get("General", "EnabledPresets", tmp) && !tmp.empty()) enabledPresets = tmp;
    else enabledPresets = activePreset; // compatibility with pre-auto-detection INIs
    if (!presetOverride.empty()) activePreset = presetOverride;
    // Paths are the one setting a shared ini genuinely cannot share. Adopting
    // the Windows LogDir on Linux would leave the overlay tailing a path that
    // cannot exist, so it would start cleanly and then silently never fire.
    // A non-Windows-looking LogDir is still honoured, so a Linux-only install
    // can just set LogDir directly; LogDirLinux always wins where present.
#ifdef _WIN32
    if (get("General", "LogDir", tmp) && !tmp.empty())        logDir = tmp;
    if (get("General", "LauncherExe", tmp) && !tmp.empty())   launcherExe = tmp;
    if (get("General", "LogDirWindows", tmp) && !tmp.empty()) logDir = tmp;
#else
    if (get("General", "LogDir", tmp) && !tmp.empty() && !looksLikeWindowsPath(tmp))
        logDir = tmp;
    if (get("General", "LauncherExe", tmp) && !tmp.empty() && !looksLikeWindowsPath(tmp))
        launcherExe = tmp;
    if (get("General", "LogDirLinux", tmp) && !tmp.empty())      logDir = tmp;
    if (get("General", "LauncherExeLinux", tmp) && !tmp.empty()) launcherExe = tmp;
#endif
    if (get("General", "DisplayMs", tmp))                     { try { displayMs = std::stoi(tmp); } catch (...) {} }
    if (get("General", "PollMs", tmp))                        { try { pollMs    = std::stoi(tmp); } catch (...) {} }
    if (get("General", "FadeInMs", tmp))                      { try { fadeInMs  = std::stoi(tmp); } catch (...) {} }
    if (get("General", "FadeOutMs", tmp))                     { try { fadeOutMs = std::stoi(tmp); } catch (...) {} }

    std::string psec = "Preset." + activePreset;

    // Reset preset-derived defaults before applying a runtime switch.
    if (activePreset == "RAC2") {
        emulatorProcs = "pcsx2-qt.exe,pcsx2.exe";
        clientComponent = "Ratchet & Clank 2 Client";
    } else if (activePreset == "RAC3") {
        emulatorProcs = "pcsx2-qt.exe,pcsx2.exe";
        clientComponent = "Ratchet and Clank 3 Client";
    } else {
        emulatorProcs = "rpcs3.exe";
        clientComponent = "Ratchet & Clank Client";
    }

    if (get(psec, "EmulatorProcesses", tmp) && !tmp.empty())  emulatorProcs = tmp;
    if (get(psec, "ClientComponent", tmp) && !tmp.empty())    clientComponent = tmp;
    if (get(psec, "OverlayColor", tmp))                       parseHexColor(tmp, overlayColor);
    if (get(psec, "BackgroundColor", tmp))                    parseHexColor(tmp, bgColor);
    if (get(psec, "VerticalPercent", tmp))                    { try { verticalPercent = std::stof(tmp); } catch (...) {} }
    // VulkanFontSize is a 1080p baseline. Preserved pre-scaling INIs do not
    // contain this key, so they keep the Vulkan default instead of inheriting
    // the independent WPF size.
    if (get(psec, "VulkanFontSize", tmp))                       { try { fontSize = std::stoi(tmp); } catch (...) {} }
    if (get(psec, "FontFamily", tmp) && !tmp.empty())         fontFamily = tmp;
    if (get(psec, "FontFallback", tmp) && !tmp.empty())       fontFallback = tmp;
    // Per-platform font overrides. FontFileLinux/FontFileWindows let one shared
    // ini serve both builds; plain FontFile applies to whichever is reading.
    if (get(psec, "FontFile", tmp) && !tmp.empty())           fontFile = tmp;
#ifdef _WIN32
    if (get(psec, "FontFileWindows", tmp) && !tmp.empty())    fontFile = tmp;
#else
    if (get(psec, "FontFileLinux", tmp) && !tmp.empty())      fontFile = tmp;
    if (get(psec, "FontFamilyLinux", tmp) && !tmp.empty())    fontFamily = tmp;
    if (get(psec, "FontFallbackLinux", tmp) && !tmp.empty())  fontFallback = tmp;
#endif

    loaded = true;
}
