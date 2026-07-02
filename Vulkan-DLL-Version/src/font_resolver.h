#pragma once
/*
 * Windows font-family -> TTF file resolver for the RandOverlay layer.
 *
 * ImGui loads fonts from files, not family names, so the configured
 * FontFamily ("HandelGothic BT") has to be resolved through the Windows font
 * registry. Per-user fonts (HKCU) are checked before system fonts (HKLM);
 * relative file names resolve against C:\Windows\Fonts.
 */
#include <windows.h>
#include <string>
#include <cctype>

namespace rofont {

// lowercase + strip spaces so "HandelGothic BT" matches "Handel Gothic BT (TrueType)"
inline std::string normalize(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s)
        if (!std::isspace(c)) out += (char)std::tolower(c);
    return out;
}

inline std::string searchFontKey(HKEY root, const char* subkey, const std::string& wantNorm) {
    HKEY key;
    if (RegOpenKeyExA(root, subkey, 0, KEY_READ, &key) != ERROR_SUCCESS) return "";

    std::string result;
    char name[512]; BYTE data[1024];
    for (DWORD i = 0;; i++) {
        DWORD nameLen = sizeof(name), dataLen = sizeof(data), type = 0;
        LONG rc = RegEnumValueA(key, i, name, &nameLen, nullptr, &type, data, &dataLen);
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc != ERROR_SUCCESS || type != REG_SZ) continue;

        // Value names look like "Handel Gothic BT (TrueType)" — match on the
        // family portion (normalized prefix), so styles/suffixes don't matter.
        std::string valueNorm = normalize(name);
        if (valueNorm.rfind(wantNorm, 0) != 0) continue;

        std::string file((const char*)data);
        if (file.empty()) continue;
        if (file.find('\\') == std::string::npos && file.find('/') == std::string::npos) {
            char windir[MAX_PATH] = {0};
            GetWindowsDirectoryA(windir, MAX_PATH);
            file = std::string(windir) + "\\Fonts\\" + file;
        }
        if (GetFileAttributesA(file.c_str()) != INVALID_FILE_ATTRIBUTES) {
            result = file;
            break;
        }
    }
    RegCloseKey(key);
    return result;
}

// Returns a full path to the family's font file, or "" if not installed.
inline std::string resolveFamilyToFile(const std::string& family) {
    if (family.empty()) return "";
    std::string want = normalize(family);
    const char* subkey = "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
    std::string p = searchFontKey(HKEY_CURRENT_USER, subkey, want);   // per-user fonts
    if (p.empty())
        p = searchFontKey(HKEY_LOCAL_MACHINE, subkey, want);           // system fonts
    return p;
}

} // namespace rofont
