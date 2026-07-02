#pragma once
/*
 * Process gating for the RandOverlay implicit Vulkan layer.
 *
 * A GLOBAL implicit layer is loaded into EVERY Vulkan application on the
 * system. This gate lets the layer self-disable in any process that is not one
 * of the supported emulators, so leaving the layer registered is safe.
 */
#include <windows.h>
#include <string>
#include <algorithm>
#include <cctype>

namespace rogate {

inline std::string currentProcessExeLower() {
    char path[MAX_PATH] = {0};
    GetModuleFileNameA(nullptr, path, MAX_PATH); // NULL => current process image
    std::string p(path);
    size_t slash = p.find_last_of("\\/");
    std::string base = (slash == std::string::npos) ? p : p.substr(slash + 1);
    std::transform(base.begin(), base.end(), base.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    return base;
}

inline bool listContains(std::string list, const std::string& exeLower) {
    std::transform(list.begin(), list.end(), list.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    size_t pos = 0;
    while (pos <= list.size()) {
        size_t comma = list.find(',', pos);
        size_t len = (comma == std::string::npos) ? std::string::npos : comma - pos;
        std::string name = list.substr(pos, len);
        size_t b = name.find_first_not_of(" \t");
        size_t e = name.find_last_not_of(" \t");
        name = (b == std::string::npos) ? std::string() : name.substr(b, e - b + 1);
        if (!name.empty() && name == exeLower) return true;
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    return false;
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
