#pragma once
/*
 * Font-family -> font-file resolver for the RandOverlay layer.
 *
 * ImGui loads fonts from files, not family names, so the configured FontFamily
 * ("HandelGothic BT") has to be resolved to a path.
 *
 *   Windows: the font registry. Per-user fonts (HKCU) before system fonts
 *            (HKLM); relative file names resolve against C:\Windows\Fonts.
 *   Linux:   fontconfig when available, otherwise a scan of the standard font
 *            directories.
 *
 * Both return "" when the family is not installed, which is what lets the
 * caller fall through to FontFallback and finally ImGui's built-in font.
 */
#include "platform.h"
#include <string>
#include <cctype>

#ifdef _WIN32
  #include <windows.h>
#else
  #include <filesystem>
  #ifdef RANDOVERLAY_HAVE_FONTCONFIG
    #include <fontconfig/fontconfig.h>
  #endif
#endif

namespace rofont {

// lowercase + strip spaces so "HandelGothic BT" matches "Handel Gothic BT (TrueType)"
inline std::string normalize(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s)
        if (!std::isspace(c)) out += (char)std::tolower(c);
    return out;
}

#ifdef _WIN32

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

#else // ── POSIX ──────────────────────────────────────────────────────────────

inline bool hasFontExtension(const std::string& path) {
    const std::string ext =
        roplat::toLower(std::filesystem::path(path).extension().string());
    return ext == ".ttf" || ext == ".otf" || ext == ".ttc" || ext == ".otc";
}

// Last-resort scan of the standard font directories, matching on file stem.
// Used when fontconfig is unavailable, and as a second chance when fontconfig
// declines to match the requested family exactly.
inline std::string scanFontDirs(const std::string& wantNorm) {
    namespace fs = std::filesystem;
    std::vector<std::string> roots;
    std::string home = roplat::homeDir(), xdg;
    if (roplat::getEnv("XDG_DATA_HOME", xdg))
        roots.push_back(roplat::joinPath(xdg, "fonts"));
    if (!home.empty()) {
        roots.push_back(roplat::joinPath(home, ".local/share/fonts"));
        roots.push_back(roplat::joinPath(home, ".fonts"));
    }
    roots.push_back("/usr/local/share/fonts");
    roots.push_back("/usr/share/fonts");

    for (const std::string& root : roots) {
        std::error_code ec;
        if (!roplat::dirExists(root)) continue;
        fs::recursive_directory_iterator it(
            root, fs::directory_options::skip_permission_denied, ec);
        if (ec) continue;
        for (const auto& entry : it) {
            if (!entry.is_regular_file(ec) || ec) continue;
            const std::string path = entry.path().string();
            if (!hasFontExtension(path)) continue;
            // "DejaVuSans.ttf" -> "dejavusans" matches a request for "DejaVu Sans".
            if (normalize(entry.path().stem().string()).rfind(wantNorm, 0) == 0)
                return path;
        }
    }
    return "";
}

#ifdef RANDOVERLAY_HAVE_FONTCONFIG
inline std::string resolveViaFontconfig(const std::string& family,
                                        const std::string& wantNorm) {
    if (!FcInit()) return "";

    FcPattern* pat = FcNameParse((const FcChar8*)family.c_str());
    if (!pat) return "";
    FcConfigSubstitute(nullptr, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);

    FcResult res = FcResultNoMatch;
    FcPattern* match = FcFontMatch(nullptr, pat, &res);
    FcPatternDestroy(pat);
    if (!match || res != FcResultMatch) {
        if (match) FcPatternDestroy(match);
        return "";
    }

    std::string path, matchedFamily;
    FcChar8* value = nullptr;
    if (FcPatternGetString(match, FC_FILE, 0, &value) == FcResultMatch && value)
        path = (const char*)value;
    value = nullptr;
    if (FcPatternGetString(match, FC_FAMILY, 0, &value) == FcResultMatch && value)
        matchedFamily = (const char*)value;
    FcPatternDestroy(match);

    // fontconfig ALWAYS returns something — asking for a font that is not
    // installed yields a substitute rather than a failure. Without this check a
    // Linux user requesting "HandelGothic BT" would silently get DejaVu Sans
    // and never learn the font was missing. Verify the match really is the
    // family we asked for, and report "" otherwise so the caller's own fallback
    // chain runs instead.
    if (path.empty()) return "";
    std::string gotNorm = normalize(matchedFamily);
    if (gotNorm.rfind(wantNorm, 0) != 0 && wantNorm.rfind(gotNorm, 0) != 0)
        return "";

    return roplat::fileExists(path) ? path : "";
}
#endif // RANDOVERLAY_HAVE_FONTCONFIG

// Returns a full path to the family's font file, or "" if not installed.
inline std::string resolveFamilyToFile(const std::string& family) {
    if (family.empty()) return "";
    const std::string want = normalize(family);

#ifdef RANDOVERLAY_HAVE_FONTCONFIG
    std::string p = resolveViaFontconfig(family, want);
    if (!p.empty()) return p;
#endif
    return scanFontDirs(want);
}

#endif // _WIN32

// Resolve the font to load: an explicit FontFile always wins, then the family
// name, then the caller's fallback family. Returns "" if nothing resolved, at
// which point ImGui's built-in font is the only remaining option.
inline std::string resolveConfigured(const std::string& fontFile,
                                     const std::string& family,
                                     const std::string& fallbackFamily) {
    if (!fontFile.empty() && roplat::fileExists(fontFile)) return fontFile;
    std::string p = resolveFamilyToFile(family);
    if (!p.empty()) return p;
    return resolveFamilyToFile(fallbackFamily);
}

} // namespace rofont
