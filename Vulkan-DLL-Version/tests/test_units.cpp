/*
 * RandOverlay headless unit tests — the pure-logic parts of the layer that do
 * NOT need a GPU or emulator: the ini reader (config.h), the process gate
 * (process_gate.h), the Archipelago log parser (log_reader.h), and the
 * dispatch-table lookup (layer_dispatch.h, Vulkan-free part only).
 *
 * The log parser is checked against tests/fixtures/archipelago-log-lines.tsv
 * at the repository root, found next to the RandOverlay.ini given as argv[1].
 *
 * Build + run: tests\run_tests.bat (Windows) or, on either platform,
 *   cmake -S . -B build && cmake --build build -j && ctest --test-dir build
 * Exit code 0 = all passed.
 */
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <chrono>
#include <filesystem>
#include <fstream>
#include "platform.h"
#include "config.h"
#include "process_gate.h"
#include "log_reader.h"
#include "font_resolver.h"
#include "arch_client_check.h"
#include "overlay_layout.h"
// Only the lookup half of the dispatch header: the rest needs the Vulkan SDK,
// which run_tests.bat does not put on the include path.
#define RANDOVERLAY_DISPATCH_LOOKUP_ONLY
#include "layer_dispatch.h"

namespace fs = std::filesystem;

static int g_pass = 0, g_fail = 0;
#define CHECK(cond, msg) do { if (cond) { g_pass++; printf("  [PASS] %s\n", msg); } \
                              else       { g_fail++; printf("  [FAIL] %s\n", msg); } } while (0)
static bool approx(float a, float b) { float d = a - b; return d < 0.01f && d > -0.01f; }

// config.h reads the environment with std::getenv, so tests must write it
// through the C runtime's view of the environment rather than the Win32 one.
static void setEnvVar(const char* name, const char* value) {
#ifdef _WIN32
    _putenv_s(name, value ? value : "");
#else
    if (value) setenv(name, value, 1); else unsetenv(name);
#endif
}

static std::string tempPath(const std::string& leaf) {
    return (fs::temp_directory_path() / leaf).string();
}
static void writeFile(const std::string& path, const char* contents) {
    FILE* f = fopen(path.c_str(), "w");
    if (f) { fputs(contents, f); fclose(f); }
}
static void appendFile(const std::string& path, const char* contents) {
    FILE* f = fopen(path.c_str(), "a");
    if (f) { fputs(contents, f); fclose(f); }
}
static void removeAll(const std::string& path) {
    std::error_code ec; fs::remove_all(path, ec);
}

// Writes `body` to a scratch ini, loads it, and points RANDOVERLAY_INI back at
// the shared ini (argv[1]) afterwards.
static RandOverlayConfig loadScratchIni(const char* leaf, const std::string& body,
                                        const char* sharedIni) {
    std::string path = tempPath(leaf);
    writeFile(path, body.c_str());
    setEnvVar("RANDOVERLAY_INI", path.c_str());
    RandOverlayConfig c; c.load();
    removeAll(path);
    if (sharedIni) setEnvVar("RANDOVERLAY_INI", sharedIni);
    return c;
}

// A stand-in for a dispatch table: the lookup is the same template either way.
static void fakeEntryPoint() {}
struct FakeDispatch {
    void (*entry)();
    int id;
};

int main(int argc, char** argv) {
    printf("=== RandOverlay unit tests ===\n\n");

    // ── process gate parsing ──────────────────────────────────────────────
    printf("[process_gate]\n");
    CHECK(rogate::listContains("rpcs3.exe", "rpcs3.exe"),                 "rpcs3.exe matches rpcs3.exe");
    CHECK(rogate::listContains("pcsx2-qt.exe,pcsx2.exe", "pcsx2.exe"),    "comma list matches pcsx2.exe");
    CHECK(rogate::listContains("pcsx2-qt.exe, pcsx2.exe", "pcsx2-qt.exe"),"whitespace-tolerant match");
    CHECK(rogate::listContains("RPCS3.EXE", "rpcs3.exe"),                 "case-insensitive (list uppercased)");
    CHECK(!rogate::listContains("rpcs3.exe", "notepad.exe"),             "notepad.exe does NOT match");
    CHECK(!rogate::listContains("", "rpcs3.exe"),                        "empty list matches nothing");
    CHECK(rogate::isProcessEnabledForPresets("rpcs3.exe", "RAC1,RAC2,RAC3"),
          "enabled RAC1 permits RPCS3");
    CHECK(!rogate::isProcessEnabledForPresets("pcsx2-qt.exe", "RAC1"),
          "RAC1-only selection does not permit PCSX2");
    CHECK(!rogate::needsWindowTitleSignals("rpcs3.exe", "RAC1,RAC2,RAC3"),
          "RPCS3 is never an ambiguous RAC2/RAC3 selection");
    CHECK(!rogate::needsWindowTitleSignals("pcsx2-qt.exe", "RAC1,RAC2"),
          "single enabled PCSX2 game is never an ambiguous RAC2/RAC3 selection");
    CHECK(rogate::needsWindowTitleSignals("pcsx2.exe", "RAC1,RAC2,RAC3"),
          "ambiguous PCSX2 selection requires window title signals");

    // Linux emulator binaries have no .exe suffix, but the ini and the
    // hardcoded lists are written in Windows terms. Both sides are normalized
    // so one set of literals serves both platforms.
    printf("[process_gate cross-platform naming]\n");
    CHECK(rogate::stripExeSuffix("rpcs3.exe") == "rpcs3", "stripExeSuffix removes .exe");
    CHECK(rogate::stripExeSuffix("rpcs3") == "rpcs3",     "stripExeSuffix is a no-op without .exe");
    CHECK(rogate::stripExeSuffix(".exe") == ".exe",       "stripExeSuffix keeps a bare .exe name");
    CHECK(rogate::listContains("rpcs3.exe", "rpcs3"),     "Linux 'rpcs3' matches the ini's rpcs3.exe");
    CHECK(rogate::listContains("pcsx2-qt.exe,pcsx2.exe", "pcsx2-qt"),
          "Linux 'pcsx2-qt' matches the ini's pcsx2-qt.exe");
    CHECK(rogate::isProcessEnabledForPresets("rpcs3", "RAC1"),
          "suffixless RPCS3 is gated in for RAC1");
    CHECK(rogate::isProcessEnabledForPresets("pcsx2-qt", "RAC3"),
          "suffixless PCSX2 is gated in for RAC3");
    CHECK(!rogate::isProcessEnabledForPresets("vulkaninfo", "RAC1,RAC2,RAC3"),
          "an unrelated Vulkan app is never gated in");
    CHECK(rogate::detectPreset("rpcs3", "RAC1", {"Ratchet & Clank [NPEA00385]"}, {}, true) == "RAC1",
          "suffixless RPCS3 still resolves to RAC1");
    CHECK(rogate::needsWindowTitleSignals("pcsx2-qt", "RAC1,RAC2,RAC3"),
          "suffixless ambiguous PCSX2 still reports needing title signals");

    printf("[automatic preset detection]\n");
    const std::vector<std::string> noTitles;
    const std::vector<std::string> rac1Title = {
        "FPS: 60.00 | Vulkan | 0.0.38 | Ratchet & Clank [NPEA00385]"};
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC1,RAC2,RAC3", rac1Title, noTitles, true) == "RAC1",
          "RPCS3 running RAC1 selects RAC1");
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC1",
                               {"FPS: 60.00 | Vulkan | 0.0.38 | Multiplayer [BORD00001]"},
                               noTitles, true) == "RAC1",
          "RPCS3 running the rac1-multiplayer PKG selects RAC1");
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC1",
                               {"RPCS3 0.0.38-18000 Alpha | master",
                                "FPS: 30.00 | Vulkan | 0.0.38 | Demon's Souls [BLUS30443]"},
                               noTitles, true).empty(),
          "RPCS3 running another game never selects RAC1");
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC1",
                               {"RPCS3 0.0.38-18000 Alpha | master"}, noTitles, true).empty(),
          "RPCS3 with no game booted never selects RAC1");
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC1",
                               {"FPS: 60.00 | Vulkan | 0.0.38 | Ratchet & Clank: Going Commando [NPUA80480]"},
                               noTitles, true).empty(),
          "RPCS3 running an HD-collection RAC2 never selects RAC1");
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC2,RAC3", rac1Title, noTitles, true).empty(),
          "RPCS3 never selects RAC1 when RAC1 is not enabled");
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC1", noTitles, noTitles, false) == "RAC1",
          "without readable titles RPCS3 alone selects RAC1");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2",
                               {"Ratchet & Clank: Going Commando | PCSX2"}, noTitles, true) == "RAC2",
          "single enabled PCSX2 game resolves from its window title");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC2",
                               {"Shadow of the Colossus | PCSX2"}, noTitles, true).empty(),
          "single enabled PCSX2 game is not selected while another game runs");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC3",
                               {"Ratchet & Clank: Going Commando | PCSX2"}, noTitles, true).empty(),
          "RAC3-only selection ignores a RAC2 window");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2", noTitles, noTitles, false) == "RAC2",
          "without readable titles a single enabled PCSX2 game needs no title signal");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2,RAC3",
                               {"Ratchet & Clank: Going Commando | PCSX2"}, noTitles, true) == "RAC2",
          "Going Commando window selects RAC2");
    CHECK(rogate::detectPreset("pcsx2.exe", "RAC1,RAC2,RAC3",
                               {"Ratchet & Clank: Up Your Arsenal | PCSX2"}, noTitles, true) == "RAC3",
          "Up Your Arsenal window selects RAC3");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2,RAC3", noTitles,
                               {"Ratchet & Clank 2 Client"}, true) == "RAC2",
          "Archipelago client title is a fallback RAC2 signal");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2,RAC3",
                               {"Ratchet & Clank 2", "Ratchet & Clank 3"}, noTitles, true).empty(),
          "conflicting PCSX2 titles never guess a preset");
    // On Linux there are never any title signals, so this is the case the
    // layer's explicit-ActivePreset fallback exists to rescue.
    CHECK(rogate::detectPreset("pcsx2-qt", "RAC1,RAC2,RAC3", noTitles, noTitles, false).empty(),
          "ambiguous PCSX2 with no title signals refuses to guess");

    // ── dispatch-table lookup ─────────────────────────────────────────────
    // A present for a queue the layer never recorded (or whose device was
    // already destroyed) must see a miss, not a zero-filled table it would
    // then call through.
    printf("[dispatch lookup]\n");
    {
        std::mutex mutex;
        std::unordered_map<void*, FakeDispatch> map;
        int keyA = 0, keyB = 0;
        FakeDispatch out = { nullptr, -1 };
        CHECK(!rodispatch::tryGet(mutex, map, (void*)&keyA, out),
              "an unrecorded dispatch key is reported as a miss");
        CHECK(map.empty(), "a miss does not insert an all-null table");
        CHECK(out.entry == nullptr && out.id == -1, "a miss leaves the caller's table untouched");

        map[(void*)&keyA] = { &fakeEntryPoint, 7 };
        CHECK(rodispatch::tryGet(mutex, map, (void*)&keyA, out) &&
              out.entry == &fakeEntryPoint && out.id == 7,
              "a recorded key copies its table out");
        CHECK(!rodispatch::tryGet(mutex, map, (void*)&keyB, out) && map.size() == 1,
              "a different key still misses without inserting");

        // The copy is the caller's own: erasing the entry (vkDestroyDevice on
        // another thread) cannot leave it dangling the way a reference would.
        map.erase((void*)&keyA);
        CHECK(out.entry == &fakeEntryPoint && out.id == 7,
              "a copied table survives its map entry being erased");
        CHECK(!rodispatch::tryGet(mutex, map, (void*)&keyA, out),
              "an erased key is a miss again");
        bool unlocked = mutex.try_lock();
        if (unlocked) mutex.unlock();
        CHECK(unlocked, "the lookup releases its lock before returning");
    }

    // ── platform abstraction ──────────────────────────────────────────────
    printf("[platform]\n");
    CHECK(!roplat::selfExePath().empty(), "selfExePath() resolves");
    CHECK(roplat::baseName(roplat::selfExePath()).find("test") != std::string::npos ||
          roplat::baseName(roplat::selfExePath()).find("units") != std::string::npos,
          "selfExePath() basename looks like this test binary");
    printf("    selfExePath = %s\n", roplat::selfExePath().c_str());
    CHECK(!roplat::moduleDir().empty(), "moduleDir() resolves");
    {
        uint64_t t0 = roplat::monotonicMs();
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        uint64_t t1 = roplat::monotonicMs();
        CHECK(t1 >= t0 + 10 && t1 < t0 + 5000, "monotonicMs() advances sanely");
    }
    CHECK(roplat::toLower("RaTcHeT") == "ratchet", "toLower");
    CHECK(roplat::startsWithNoCase("Generate_x.txt", "generate_"), "startsWithNoCase");
    CHECK(!roplat::startsWithNoCase("gen", "generate_"), "startsWithNoCase rejects short input");
    CHECK(!roplat::defaultArchipelagoLogDir().empty(), "a default log dir is always proposed");
    printf("    defaultArchipelagoLogDir = %s\n", roplat::defaultArchipelagoLogDir().c_str());
    CHECK(!roplat::fileExists("/definitely/not/here.txt"), "fileExists rejects a missing path");

    // ── config / ini parsing ──────────────────────────────────────────────
    printf("[config] ini=%s\n", argc > 1 ? argv[1] : "(none supplied)");
    if (argc > 1) setEnvVar("RANDOVERLAY_INI", argv[1]);
    RandOverlayConfig cfg; cfg.load();
    CHECK(cfg.loaded,                          "ini loaded");
    CHECK(cfg.activePreset == "RAC1",          "ActivePreset = RAC1");
    CHECK(approx(cfg.overlayColor[0], 0.502f) && approx(cfg.overlayColor[1], 0.627f) &&
          approx(cfg.overlayColor[2], 0.816f), "OverlayColor #80A0D0 -> (0.502,0.627,0.816)");
    CHECK(approx(cfg.bgColor[0], 0.118f),      "BackgroundColor #1E1E1E -> ~0.118");
    CHECK(approx(cfg.verticalPercent, 0.17f),  "VerticalPercent = 0.17");
    CHECK(cfg.displayMs == 5000,               "DisplayMs = 5000");
    CHECK(cfg.pollMs == 1500,                  "PollMs = 1500 (parity)");
    CHECK(cfg.fadeInMs == 300,                 "FadeInMs = 300 (parity)");
    CHECK(cfg.fadeOutMs == 500,                "FadeOutMs = 500 (parity)");
    CHECK(cfg.fontSize == 48,                  "VulkanFontSize = 48");
    CHECK(cfg.emulatorProcs.find("rpcs3") != std::string::npos, "RAC1 EmulatorProcesses has rpcs3");
    // The shared ini's LogDir is a Windows path. Adopting it on Linux would
    // leave the overlay tailing a directory that cannot exist — it would start
    // cleanly and then silently never fire, which is the worst failure shape.
#ifdef _WIN32
    CHECK(cfg.launcherExe.find("ArchipelagoLauncher") != std::string::npos, "LauncherExe read");
    CHECK(cfg.logDir == "C:\\ProgramData\\Archipelago\\logs", "Windows LogDir honoured");
#else
    CHECK(!rocfg_detail::looksLikeWindowsPath(cfg.logDir),
          "a Windows LogDir is never adopted on Linux");
    CHECK(cfg.logDir == roplat::defaultArchipelagoLogDir(),
          "Linux falls back to the probed default log dir");
#endif
    CHECK(rocfg_detail::looksLikeWindowsPath("C:\\ProgramData\\x"), "drive-letter path detected");
    CHECK(rocfg_detail::looksLikeWindowsPath("dir\\sub"),           "backslash path detected");
    CHECK(!rocfg_detail::looksLikeWindowsPath("/home/me/logs"),     "POSIX path not misdetected");
    // The shared ini carries both the Windows families and their Linux
    // counterparts; each build reads only the pair that exists on it.
#ifdef _WIN32
    CHECK(cfg.fontFamily == "HandelGothic BT",  "FontFamily = HandelGothic BT");
    CHECK(cfg.fontFallback == "Bahnschrift",    "FontFallback = Bahnschrift");
#else
    CHECK(cfg.fontFamily == "DejaVu Sans",      "FontFamilyLinux overrides FontFamily");
    CHECK(cfg.fontFallback == "Liberation Sans","FontFallbackLinux overrides FontFallback");
#endif
    CHECK(cfg.clientComponent == "Ratchet & Clank Client",
          "RAC1 ClientComponent = Ratchet & Clank Client");
    CHECK(cfg.enabledPresets == "RAC1", "legacy INI falls back to ActivePreset as enabled set");
    CHECK(cfg.warning.empty(), "the shared ini raises no config warning");

    // Existing installations preserve their INI during upgrades. Before
    // VulkanFontSize existed they only had WpfFontSize, which must not lower
    // the new Vulkan baseline.
    {
        std::string legacy = tempPath("randoverlay_legacy_font.ini");
        writeFile(legacy, "[General]\nActivePreset=RAC1\n[Preset.RAC1]\nWpfFontSize=43\n");
        setEnvVar("RANDOVERLAY_INI", legacy.c_str());
        RandOverlayConfig legacyCfg; legacyCfg.load();
        CHECK(legacyCfg.fontSize == 48,
              "legacy WpfFontSize does not override Vulkan 48px baseline");
        removeAll(legacy);
        if (argc > 1) setEnvVar("RANDOVERLAY_INI", argv[1]);
    }

    // Preset-derived ClientComponent default (RAC3 preset, no explicit key)
    {
        std::string mini = tempPath("randoverlay_mini.ini");
        writeFile(mini, "[General]\nActivePreset=RAC3\nEnabledPresets=RAC1,RAC2,RAC3\n");
        setEnvVar("RANDOVERLAY_INI", mini.c_str());
        RandOverlayConfig c3; c3.load();
        CHECK(c3.clientComponent == "Ratchet and Clank 3 Client",
              "RAC3 default ClientComponent derived from preset");
        CHECK(c3.enabledPresets == "RAC1,RAC2,RAC3", "EnabledPresets list loaded");
        c3.load("RAC2");
        CHECK(c3.activePreset == "RAC2" && c3.clientComponent == "Ratchet & Clank 2 Client" &&
              c3.emulatorProcs.find("pcsx2") != std::string::npos,
              "runtime preset override reloads RAC2 configuration");
        removeAll(mini);
        if (argc > 1) setEnvVar("RANDOVERLAY_INI", argv[1]); // restore
    }

    // FontFile is the escape hatch for platforms with no font registry.
    {
        std::string fontIni = tempPath("randoverlay_fontfile.ini");
        std::string fake    = tempPath("randoverlay_fake_font.ttf");
        writeFile(fake, "not really a font");
        std::string body = "[General]\nActivePreset=RAC1\n[Preset.RAC1]\nFontFile=" + fake + "\n";
        writeFile(fontIni, body.c_str());
        setEnvVar("RANDOVERLAY_INI", fontIni.c_str());
        RandOverlayConfig fc; fc.load();
        CHECK(fc.fontFile == fake, "FontFile= is read from the preset section");
        CHECK(rofont::resolveConfigured(fc.fontFile, "Definitely Not A Font 123",
                                        "Also Not A Font 456") == fake,
              "an explicit FontFile wins over family resolution");
        CHECK(rofont::resolveConfigured("/no/such/font.ttf", "Definitely Not A Font 123",
                                        "Also Not A Font 456").empty(),
              "a missing FontFile falls through instead of being trusted");
        removeAll(fontIni);
        removeAll(fake);
        if (argc > 1) setEnvVar("RANDOVERLAY_INI", argv[1]);
    }

    // ActivePreset is case-insensitive and validated, as in AHK and PS+WPF. On
    // Linux it is the only thing telling RAC2 from RAC3, so a lowercase value
    // silently selecting RAC1 would pick the wrong game.
    printf("[config ActivePreset]\n");
    const char* sharedIni = argc > 1 ? argv[1] : nullptr;
    {
        RandOverlayConfig c = loadScratchIni("randoverlay_preset_case.ini",
            "[General]\nActivePreset= rac2 \n"
            "[Preset.RAC2]\nVerticalPercent=0.42\nVulkanFontSize=40\n", sharedIni);
        CHECK(c.activePreset == "RAC2", "ActivePreset=rac2 resolves to RAC2");
        CHECK(approx(c.verticalPercent, 0.42f) && c.fontSize == 40,
              "ActivePreset=rac2 honours the [Preset.RAC2] section");
        CHECK(c.emulatorProcs.find("pcsx2") != std::string::npos &&
              c.clientComponent == "Ratchet & Clank 2 Client",
              "ActivePreset=rac2 takes the RAC2 preset defaults");
        CHECK(c.enabledPresets == "RAC2", "legacy EnabledPresets fallback uses the normalised preset");
        CHECK(c.warning.empty(), "a known preset in any case raises no warning");
    }
    {
        RandOverlayConfig c = loadScratchIni("randoverlay_preset_unknown.ini",
            "[General]\nActivePreset=RAC4\n"
            "[Preset.RAC1]\nVerticalPercent=0.3\n"
            "[Preset.RAC4]\nVerticalPercent=0.9\n", sharedIni);
        CHECK(c.activePreset == "RAC1", "ActivePreset=RAC4 falls back to RAC1");
        CHECK(approx(c.verticalPercent, 0.3f) && c.emulatorProcs == "rpcs3.exe",
              "ActivePreset=RAC4 reads [Preset.RAC1], not [Preset.RAC4]");
        CHECK(c.warning == "Unknown ActivePreset 'RAC4'; using RAC1 defaults.",
              "ActivePreset=RAC4 warns in the AHK/PS wording");
        printf("    warning: %s\n", c.warning.c_str());
    }

    // Numeric values are rejected, not clamped, exactly as AHK and PS+WPF do:
    // whole-string integers with a minimum, and VerticalPercent within 0..1.
    // The first problem is the one reported.
    printf("[config numeric validation]\n");
    {
        RandOverlayConfig c = loadScratchIni("randoverlay_numeric_bad.ini",
            "[General]\nActivePreset=RAC1\nDisplayMs=0\nPollMs=12abc\nFadeInMs=-1\nFadeOutMs=0\n"
            "[Preset.RAC1]\nVerticalPercent=5.0\nVulkanFontSize=0\n", sharedIni);
        CHECK(c.displayMs == 5000,  "DisplayMs=0 is rejected (minimum 1)");
        CHECK(c.pollMs == 1500,     "PollMs=12abc is rejected, not read as 12");
        CHECK(c.fadeInMs == 300,    "FadeInMs=-1 is rejected (minimum 0)");
        CHECK(c.fadeOutMs == 0,     "FadeOutMs=0 is accepted (minimum 0)");
        CHECK(approx(c.verticalPercent, 0.17f), "VerticalPercent=5.0 is rejected, not clamped");
        CHECK(c.fontSize == 48,     "VulkanFontSize=0 is rejected (minimum 1)");
        CHECK(c.warning == "Invalid General.DisplayMs; using default.",
              "the first invalid value is the one reported");
    }
    {
        RandOverlayConfig c = loadScratchIni("randoverlay_numeric_poll.ini",
            "[General]\nPollMs=12abc\n", sharedIni);
        CHECK(c.pollMs == 1500 && c.warning == "Invalid General.PollMs; using default.",
              "a partial number warns as Invalid General.PollMs");
    }
    {
        RandOverlayConfig c = loadScratchIni("randoverlay_numeric_vp.ini",
            "[General]\nActivePreset=RAC1\n[Preset.RAC1]\nVerticalPercent=5.0\n", sharedIni);
        CHECK(approx(c.verticalPercent, 0.17f) &&
              c.warning == "Invalid Preset.RAC1.VerticalPercent; using default.",
              "VerticalPercent=5.0 warns as Invalid Preset.RAC1.VerticalPercent");
    }
    {
        const char* rejected[] = { "-0.1", "1.5", "0.5x", ".5", "1.", "abc", "1e-1" };
        for (const char* v : rejected) {
            std::string body = std::string("[General]\nActivePreset=RAC1\n[Preset.RAC1]\nVerticalPercent=") + v + "\n";
            RandOverlayConfig c = loadScratchIni("randoverlay_numeric_vp2.ini", body, sharedIni);
            std::string label = std::string("VerticalPercent=") + v + " is rejected";
            CHECK(approx(c.verticalPercent, 0.17f) && !c.warning.empty(), label.c_str());
        }
        const char* accepted[] = { "0", "1", "1.0", "0.25" };
        const float values[]   = { 0.0f, 1.0f, 1.0f, 0.25f };
        for (int i = 0; i < 4; i++) {
            std::string body = std::string("[General]\nActivePreset=RAC1\n[Preset.RAC1]\nVerticalPercent=") + accepted[i] + "\n";
            RandOverlayConfig c = loadScratchIni("randoverlay_numeric_vp3.ini", body, sharedIni);
            std::string label = std::string("VerticalPercent=") + accepted[i] + " is accepted";
            CHECK(approx(c.verticalPercent, values[i]) && c.warning.empty(), label.c_str());
        }
    }
    {
        RandOverlayConfig c = loadScratchIni("randoverlay_numeric_edge.ini",
            "[General]\nDisplayMs=99999999999\nPollMs=\nFadeInMs=+5\n", sharedIni);
        CHECK(c.displayMs == 5000, "an out-of-range integer is rejected");
        CHECK(c.pollMs == 1500,    "an empty value keeps the default");
        CHECK(c.fadeInMs == 300,   "a leading '+' is rejected like AHK's ^-?\\d+$");
        CHECK(c.warning == "Invalid General.DisplayMs; using default.",
              "an empty value is not reported, an out-of-range one is");
        c.load(); // RANDOVERLAY_INI points at the shared, clean ini again
        CHECK(c.warning.empty(), "each load starts with no warning");
    }

    // The layer reloads with the detected preset on every switch. Each load
    // starts from the defaults, as the AHK and PS+WPF runtimes' one load does,
    // so nothing the previous preset or ini set survives a key going missing.
    printf("[config reload]\n");
    {
        std::string path = tempPath("randoverlay_reload.ini");
        writeFile(path,
            "[General]\nActivePreset=RAC1\nEnabledPresets=RAC1,RAC2,RAC3\n"
            "[Preset.RAC1]\nOverlayColor=#FF0000\nBackgroundColor=#00FF00\n"
            "VerticalPercent=0.42\nVulkanFontSize=30\nFontFamily=Custom Family\n"
            "FontFallback=Custom Fallback\nFontFile=custom-font.ttf\n"
            "[Preset.RAC2]\nVerticalPercent=0.6\n");
        setEnvVar("RANDOVERLAY_INI", path.c_str());
        RandOverlayConfig c; c.load();
        CHECK(approx(c.overlayColor[0], 1.0f) && approx(c.bgColor[1], 1.0f) &&
              approx(c.verticalPercent, 0.42f) && c.fontSize == 30 &&
              c.fontFamily == "Custom Family" && c.fontFallback == "Custom Fallback" &&
              c.fontFile == "custom-font.ttf",
              "RAC1 reads every key of its own section");

        RandOverlayConfig defaults;
        c.load("RAC2");
        CHECK(c.activePreset == "RAC2" && approx(c.verticalPercent, 0.6f),
              "switching to RAC2 reads [Preset.RAC2]");
        CHECK(approx(c.overlayColor[0], defaults.overlayColor[0]) &&
              approx(c.overlayColor[1], defaults.overlayColor[1]) &&
              approx(c.overlayColor[2], defaults.overlayColor[2]),
              "a switch to a preset without OverlayColor takes the default, not RAC1's");
        CHECK(approx(c.bgColor[0], defaults.bgColor[0]) &&
              approx(c.bgColor[1], defaults.bgColor[1]) &&
              approx(c.bgColor[2], defaults.bgColor[2]),
              "a switch to a preset without BackgroundColor takes the default");
        CHECK(c.fontSize == defaults.fontSize, "VulkanFontSize does not carry over a switch");
        CHECK(c.fontFamily == defaults.fontFamily && c.fontFallback == defaults.fontFallback,
              "FontFamily and FontFallback do not carry over a switch");
        CHECK(c.fontFile.empty(), "FontFile does not carry over a switch");

        c.load("RAC1");
        CHECK(approx(c.overlayColor[0], 1.0f) && approx(c.verticalPercent, 0.42f) &&
              c.fontFile == "custom-font.ttf",
              "switching back to RAC1 restores its own section");

        // An invalid value on the new preset falls back to the default too.
        writeFile(path,
            "[General]\nActivePreset=RAC1\nEnabledPresets=RAC1,RAC2,RAC3\n"
            "[Preset.RAC1]\nOverlayColor=#FF0000\nVerticalPercent=0.42\n"
            "[Preset.RAC2]\nOverlayColor=not-a-colour\nVerticalPercent=7\n");
        c.load("RAC1");
        c.load("RAC2");
        CHECK(approx(c.overlayColor[0], defaults.overlayColor[0]) &&
              approx(c.verticalPercent, defaults.verticalPercent),
              "a rejected value on the new preset takes the default, not the old preset's");

        // No ActivePreset: RAC1, whatever the previous load resolved.
        writeFile(path,
            "[General]\nActivePreset=RAC3\nDisplayMs=7000\nLogDir=custom-logs\n");
        c.load();
        CHECK(c.activePreset == "RAC3" && c.enabledPresets == "RAC3" && c.displayMs == 7000 &&
              c.logDir == "custom-logs",
              "ActivePreset=RAC3 with DisplayMs and LogDir set");
        writeFile(path, "[General]\nPollMs=900\n");
        c.load();
        CHECK(c.activePreset == "RAC1", "an ini without ActivePreset resolves RAC1, not the last preset");
        CHECK(c.enabledPresets == "RAC1", "the legacy EnabledPresets fallback follows the reset preset");
        CHECK(c.emulatorProcs == "rpcs3.exe" && c.clientComponent == "Ratchet & Clank Client",
              "the RAC1 preset defaults follow the reset preset");
        CHECK(c.displayMs == defaults.displayMs && c.logDir == defaults.logDir && c.pollMs == 900,
              "[General] keys the ini no longer sets return to their defaults");
        c.load("RAC2");
        writeFile(path, "[General]\n");
        c.load();
        CHECK(c.activePreset == "RAC1", "a runtime override does not outlive the next plain load");

        removeAll(path);
        if (argc > 1) setEnvVar("RANDOVERLAY_INI", argv[1]);
    }

    { float c[3] = {9,9,9}; CHECK(!rocfg_detail::parseHexColor("#ZZZZZZ", c), "malformed hex rejected"); }
    { float c[3] = {0,0,0}; CHECK(rocfg_detail::parseHexColor("#FF0000", c) && approx(c[0],1.0f) &&
                                  approx(c[1],0.0f) && approx(c[2],0.0f), "#FF0000 -> (1,0,0)"); }

    // Resolution-aware Vulkan layout: moderated scaling selected for parity
    // across windowed, 1440p, and 4K output sizes.
    printf("[overlay_layout]\n");
    CHECK(approx(rolayout::metricsForHeight(720.0f, 48.0f).fontPx, 36.0f),
          "720p uses 36px font");
    CHECK(approx(rolayout::metricsForHeight(1080.0f, 48.0f).fontPx, 48.0f),
          "1080p uses 48px font");
    CHECK(approx(rolayout::metricsForHeight(1440.0f, 48.0f).fontPx, 60.0f),
          "1440p uses 60px font");
    CHECK(approx(rolayout::metricsForHeight(2160.0f, 48.0f).fontPx, 72.0f),
          "4K uses 72px font");
    CHECK(approx(rolayout::metricsForHeight(1080.0f, 48.0f).paddingX, 12.0f) &&
          approx(rolayout::metricsForHeight(2160.0f, 48.0f).paddingX, 18.0f),
          "panel spacing scales with resolution");

    // ── Archipelago log parsing ───────────────────────────────────────────
    printf("[log_reader]\n");
    std::string dir = tempPath("randoverlay_test_logs");
    removeAll(dir);
    fs::create_directories(dir);
    std::string logf = (fs::path(dir) / "Launcher_unittest.txt").string();
    writeFile(logf, "seed line ignored\n");

    LogReader lr(dir); // seeds on the existing 1 line
    appendFile(logf, "[Client at 12:00:00]: Ratchet found their Hydrodisplacer (RAC1)\n");
    auto msgs = lr.poll();
    CHECK(!msgs.empty(), "poll() picks up the appended event line");
    if (!msgs.empty()) {
        printf("    parsed: \"%s\"\n", msgs.back().text.c_str());
        CHECK(msgs.back().text.find("found their") != std::string::npos, "message keeps 'found their'");
        CHECK(msgs.back().text.find("(RAC1)") == std::string::npos,      "parenthesized suffix stripped");
        CHECK(msgs.back().timestamp > 0,                                 "message carries a timestamp");
    }
    appendFile(logf, "[Client at 12:00:01]: routine chatter line\n");
    CHECK(lr.poll().empty(), "non-event chatter is ignored");
    appendFile(logf, "[Client at 12:00:02]: (Ratchet found their Gold Bolt)\n");
    CHECK(lr.poll().empty(), "an event that strips to nothing is never emitted as empty text");
    removeAll(dir);

    // ── Shared line contract (same fixture as the AHK and PS+WPF runtimes) ─
    // Rows are "<input><TAB><expected>", split on the LAST tab; "<none>" means
    // not shown; '#' and blank lines are skipped. Some inputs end in spaces on
    // purpose, so nothing but '\r' is trimmed from a row.
    printf("[log_reader line contract]\n");
    {
        std::string fixture;
        if (argc > 1)
            fixture = (fs::path(argv[1]).parent_path() / "tests" / "fixtures" /
                       "archipelago-log-lines.tsv").string();
        std::ifstream in(fixture, std::ios::binary);
        CHECK(in.is_open(), "shared fixture tests/fixtures/archipelago-log-lines.tsv opened");
        if (!in.is_open())
            printf("    looked for: %s (pass the repo-root RandOverlay.ini as argv[1])\n",
                   fixture.empty() ? "(no argv[1])" : fixture.c_str());
        int rows = 0, malformed = 0;
        std::string row;
        while (std::getline(in, row)) {
            if (!row.empty() && row.back() == '\r') row.pop_back();
            if (row.empty() || row[0] == '#') continue;
            size_t tab = row.rfind('\t');
            if (tab == std::string::npos) { malformed++; continue; }
            std::string input = row.substr(0, tab);
            std::string expected = row.substr(tab + 1);
            if (expected == "<none>") expected.clear();
            std::string got = rolog::formatEvent(input);
            rows++;
            std::string label = "fixture: " + input;
            CHECK(got == expected, label.c_str());
            if (got != expected)
                printf("    expected \"%s\", got \"%s\"\n", expected.c_str(), got.c_str());
        }
        CHECK(malformed == 0, "every fixture row has a tab-separated expectation");
        CHECK(rows > 0, "fixture contributed rows");
        printf("    %d fixture rows\n", rows);
    }

    // ── Log selection parity (AHK/PS: any *.txt except Generate_/Server_) ─
    printf("[log_reader selection parity]\n");
    std::string dir2 = tempPath("randoverlay_test_logs2");
    removeAll(dir2);
    fs::create_directories(dir2);
    std::string clientLog = (fs::path(dir2) / "RAC2Client_unittest.txt").string(); // non-Launcher_ name
    std::string genLog    = (fs::path(dir2) / "Generate_unittest.txt").string();
    writeFile(clientLog, "seed\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(30)); // Generate_ gets the NEWER write time
    writeFile(genLog, "[Client at 1:00:00]: decoy found their trap (X)\n");

    LogReader lr2(dir2);
    CHECK(roplat::baseName(lr2.currentLogFile()) == "RAC2Client_unittest.txt",
          "newest-file scan skips the Generate_ decoy");
    appendFile(clientLog, "[Client at 1:00:01]: Ratchet found their Persuader (RAC2)\n");
    auto msgs2 = lr2.poll();
    CHECK(!msgs2.empty(), "non-Launcher_ client log is tailed");
    if (!msgs2.empty())
        CHECK(msgs2.back().text.find("Persuader") != std::string::npos,
              "event came from client log, not the newer Generate_ decoy");
    removeAll(dir2);

    // ── Rotation in place (same file name, truncated and rewritten) ───────
    // The size guard used to skip any poll where the file was not larger than
    // before, so a truncated log showed nothing until it outgrew its old size.
    printf("[log_reader truncation]\n");
    {
        std::string dir3 = tempPath("randoverlay_test_logs3");
        removeAll(dir3);
        fs::create_directories(dir3);
        std::string rot = (fs::path(dir3) / "Client_rotation.txt").string();
        writeFile(rot,
            "[Client at 1:00:00]: chatter chatter chatter chatter chatter chatter\n"
            "[Client at 1:00:01]: chatter chatter chatter chatter chatter chatter\n"
            "[Client at 1:00:02]: chatter chatter chatter chatter chatter chatter\n"
            "[Client at 1:00:03]: chatter chatter chatter chatter chatter chatter\n");
        LogReader lr3(dir3); // seeds on 4 lines

        writeFile(rot, "[Client at 2:00:00]: Ratchet found their Gold Bolt (Kerwan)\n");
        auto m1 = lr3.poll();
        CHECK(!m1.empty() && m1.back().text == "Ratchet found their Gold Bolt",
              "a log truncated to fewer bytes is read again from the top");

        appendFile(rot, "[Client at 2:00:01]: Clank found their Swingshot (Kerwan)\n");
        auto m2 = lr3.poll();
        CHECK(m2.size() == 1 && m2.back().text == "Clank found their Swingshot",
              "the truncated log keeps being tailed as it regrows");

        CHECK(lr3.poll().empty(), "an unchanged log yields nothing");

        // Cut and already regrown past its old size before the next poll:
        // only the line count shows it.
        std::string longLine = "[Client at 3:00:00]: Ratchet found their " +
                               std::string(200, 'x') + " (Somewhere)\n";
        writeFile(rot, longLine.c_str());
        auto m3 = lr3.poll();
        CHECK(m3.size() == 1 && m3.back().text.find("Ratchet found their xxx") == 0,
              "a log rewritten larger but with fewer lines is read from the top");
        removeAll(dir3);
    }

    // A missing log directory must degrade quietly, not throw. On Linux the
    // default path frequently does not exist until Archipelago has run once.
    {
        LogReader missing(tempPath("randoverlay_no_such_log_dir"));
        CHECK(missing.currentLogFile().empty(), "missing log dir yields no current file");
        CHECK(missing.poll().empty(),           "polling a missing log dir is a quiet no-op");
    }

    // ── Font resolver ─────────────────────────────────────────────────────
    printf("[font_resolver]\n");
    CHECK(rofont::normalize("Handel Gothic BT") == "handelgothicbt", "normalize strips spaces/case");
    // The load-bearing test on Linux: fontconfig ALWAYS returns a substitute
    // for an unknown family, so without an explicit verification step a missing
    // font would silently resolve to something arbitrary.
    CHECK(rofont::resolveFamilyToFile("Definitely Not A Font 123").empty(),
          "unknown family resolves to empty (no silent substitution)");
    CHECK(rofont::resolveFamilyToFile("").empty(), "empty family resolves to empty");
    {
#ifdef _WIN32
        const char* likely = "Bahnschrift";   // ships with Win10/11
#else
        const char* likely = "DejaVu Sans";   // near-universal on Linux
#endif
        std::string p = rofont::resolveFamilyToFile(likely);
        if (p.empty()) {
            printf("    (%s not installed - fallback path will be used)\n", likely);
        } else {
            CHECK(roplat::fileExists(p), "a known family resolves to an existing file");
            printf("    %s -> %s\n", likely, p.c_str());
        }
    }

    // ── Archipelago process check (informational — depends on live state) ─
    printf("[arch_client_check]\n");
    printf("    isArchipelagoRunning() = %s\n", roarch::isArchipelagoRunning() ? "true" : "false");
    setEnvVar("RANDOVERLAY_NO_PROMPT", "1");
    CHECK(roarch::promptIfNotRunning("", "RAC1", "") == roarch::isArchipelagoRunning(),
          "promptIfNotRunning reports the running state without prompting");
#ifdef _WIN32
    CHECK(roarch::claimPromptForProcess(), "first prompt claim in a process succeeds");
    CHECK(!roarch::claimPromptForProcess(), "a second prompt claim in the same process is refused");
#endif

    printf("\n=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
