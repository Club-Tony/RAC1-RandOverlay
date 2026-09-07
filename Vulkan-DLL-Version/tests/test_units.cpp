/*
 * RandOverlay headless unit tests — the pure-logic parts of the layer that do
 * NOT need a GPU or emulator: the ini reader (config.h), the process gate
 * (process_gate.h), and the Archipelago log parser (log_reader.h).
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
#include "platform.h"
#include "config.h"
#include "process_gate.h"
#include "log_reader.h"
#include "font_resolver.h"
#include "arch_client_check.h"
#include "overlay_layout.h"

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
          "RPCS3 preset resolution never waits on desktop window titles");
    CHECK(!rogate::needsWindowTitleSignals("pcsx2-qt.exe", "RAC1,RAC2"),
          "single enabled PCSX2 game never waits on desktop window titles");
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
    CHECK(rogate::detectPreset("rpcs3", "RAC1", {}, {}) == "RAC1",
          "suffixless RPCS3 still resolves to RAC1");
    CHECK(rogate::needsWindowTitleSignals("pcsx2-qt", "RAC1,RAC2,RAC3"),
          "suffixless ambiguous PCSX2 still reports needing title signals");

    printf("[automatic preset detection]\n");
    const std::vector<std::string> noTitles;
    CHECK(rogate::detectPreset("rpcs3.exe", "RAC1,RAC2,RAC3", noTitles, noTitles) == "RAC1",
          "RPCS3 deterministically selects RAC1");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2", noTitles, noTitles) == "RAC2",
          "single enabled PCSX2 game needs no title signal");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2,RAC3",
                               {"Ratchet & Clank: Going Commando | PCSX2"}, noTitles) == "RAC2",
          "Going Commando window selects RAC2");
    CHECK(rogate::detectPreset("pcsx2.exe", "RAC1,RAC2,RAC3",
                               {"Ratchet & Clank: Up Your Arsenal | PCSX2"}, noTitles) == "RAC3",
          "Up Your Arsenal window selects RAC3");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2,RAC3", noTitles,
                               {"Ratchet & Clank 2 Client"}) == "RAC2",
          "Archipelago client title is a fallback RAC2 signal");
    CHECK(rogate::detectPreset("pcsx2-qt.exe", "RAC1,RAC2,RAC3",
                               {"Ratchet & Clank 2", "Ratchet & Clank 3"}, noTitles).empty(),
          "conflicting PCSX2 titles never guess a preset");
    // On Linux there are never any title signals, so this is the case the
    // layer's explicit-ActivePreset fallback exists to rescue.
    CHECK(rogate::detectPreset("pcsx2-qt", "RAC1,RAC2,RAC3", noTitles, noTitles).empty(),
          "ambiguous PCSX2 with no title signals refuses to guess");

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
    removeAll(dir);

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

    printf("\n=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
