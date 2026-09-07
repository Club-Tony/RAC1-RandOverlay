#pragma once
/*
 * Process gating for the RandOverlay implicit Vulkan layer.
 *
 * A GLOBAL implicit layer is loaded into EVERY Vulkan application on the
 * system. This gate lets the layer self-disable in any process that is not one
 * of the supported emulators, so leaving the layer registered is safe.
 */
#include "platform.h"
#include <string>
#include <vector>
#include <algorithm>
#include <cctype>

namespace rogate {

// Drop a trailing ".exe" so the Windows process names carried in the ini and in
// the hardcoded lists below also match their Linux counterparts, where the same
// binaries are simply "rpcs3" / "pcsx2-qt". Applied to both sides of every
// comparison, so one set of literals serves both platforms.
inline std::string stripExeSuffix(const std::string& s) {
    const std::string ext = ".exe";
    if (s.size() > ext.size() &&
        s.compare(s.size() - ext.size(), ext.size(), ext) == 0)
        return s.substr(0, s.size() - ext.size());
    return s;
}

inline std::string currentProcessExeLower() {
    return roplat::toLower(roplat::baseName(roplat::selfExePath()));
}

inline bool listContains(std::string list, const std::string& exeLower) {
    std::string needle = stripExeSuffix(roplat::toLower(exeLower));
    list = roplat::toLower(list);
    size_t pos = 0;
    while (pos <= list.size()) {
        size_t comma = list.find(',', pos);
        size_t len = (comma == std::string::npos) ? std::string::npos : comma - pos;
        std::string name = list.substr(pos, len);
        size_t b = name.find_first_not_of(" \t");
        size_t e = name.find_last_not_of(" \t");
        name = (b == std::string::npos) ? std::string() : name.substr(b, e - b + 1);
        if (!name.empty() && stripExeSuffix(name) == needle) return true;
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    return false;
}

inline bool isProcessEnabledForPresets(const std::string& exeLower,
                                       const std::string& enabledPresets) {
    if (listContains("rpcs3.exe", exeLower))
        return listContains(enabledPresets, "RAC1");
    if (listContains("pcsx2-qt.exe,pcsx2.exe", exeLower))
        return listContains(enabledPresets, "RAC2") ||
               listContains(enabledPresets, "RAC3");
    return false;
}

inline bool needsWindowTitleSignals(const std::string& exeLower,
                                    const std::string& enabledPresets) {
    return listContains("pcsx2-qt.exe,pcsx2.exe", exeLower) &&
           listContains(enabledPresets, "RAC2") &&
           listContains(enabledPresets, "RAC3");
}

inline int presetMatchesInTitles(const std::vector<std::string>& titles,
                                 bool rac2Enabled, bool rac3Enabled) {
    int matches = 0;
    for (std::string title : titles) {
        std::transform(title.begin(), title.end(), title.begin(),
                       [](unsigned char c) { return (char)std::tolower(c); });
        if (rac2Enabled &&
            (title.find("ratchet & clank 2") != std::string::npos ||
             title.find("ratchet and clank 2") != std::string::npos ||
             title.find("going commando") != std::string::npos ||
             title.find("locked and loaded") != std::string::npos))
            matches |= 1;
        if (rac3Enabled &&
            (title.find("ratchet & clank 3") != std::string::npos ||
             title.find("ratchet and clank 3") != std::string::npos ||
             title.find("up your arsenal") != std::string::npos))
            matches |= 2;
    }
    return matches;
}

// Resolve the active game without guessing. The emulator's own title wins;
// an Archipelago client title is used only when PCSX2 has no game title yet.
inline std::string detectPreset(const std::string& exeLower,
                                const std::string& enabledPresets,
                                const std::vector<std::string>& emulatorTitles,
                                const std::vector<std::string>& clientTitles) {
    bool rac1 = listContains(enabledPresets, "RAC1");
    bool rac2 = listContains(enabledPresets, "RAC2");
    bool rac3 = listContains(enabledPresets, "RAC3");

    if (listContains("rpcs3.exe", exeLower)) return rac1 ? "RAC1" : "";
    if (!listContains("pcsx2-qt.exe,pcsx2.exe", exeLower)) return "";
    if (rac2 && !rac3) return "RAC2";
    if (rac3 && !rac2) return "RAC3";
    if (!rac2 && !rac3) return "";

    int emulatorMatch = presetMatchesInTitles(emulatorTitles, rac2, rac3);
    if (emulatorMatch == 1) return "RAC2";
    if (emulatorMatch == 2) return "RAC3";
    if (emulatorMatch == 3) return "";

    int clientMatch = presetMatchesInTitles(clientTitles, rac2, rac3);
    if (clientMatch == 1) return "RAC2";
    if (clientMatch == 2) return "RAC3";
    return "";
}

// True if the host process is one of the supported emulators. Accepts both the
// configured (comma-separated) list AND the RAC1/2/3 union as a safety net, so
// the overlay activates even if the ini's ActivePreset does not match the
// emulator that is actually running.
inline bool isTargetProcess(const std::string& configuredList) {
    std::string exe = currentProcessExeLower();
    if (listContains(configuredList, exe)) return true;
    return listContains("rpcs3.exe,pcsx2-qt.exe,pcsx2.exe", exe);
}

} // namespace rogate
