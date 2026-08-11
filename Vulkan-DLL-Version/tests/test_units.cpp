/*
 * RandOverlay headless unit tests — the pure-logic parts of the layer that do
 * NOT need a GPU or emulator: the ini reader (config.h), the process gate
 * (process_gate.h), and the Archipelago log parser (log_reader.h).
 *
 * Build + run: tests\run_tests.bat   (or see that file for the g++ line)
 * Exit code 0 = all passed.
 */
#include <cstdio>
#include <string>
#include <windows.h>
#include "config.h"
#include "process_gate.h"
#include "log_reader.h"
#include "font_resolver.h"
#include "arch_client_check.h"
#include "overlay_layout.h"

static int g_pass = 0, g_fail = 0;
#define CHECK(cond, msg) do { if (cond) { g_pass++; printf("  [PASS] %s\n", msg); } \
                              else       { g_fail++; printf("  [FAIL] %s\n", msg); } } while (0)
static bool approx(float a, float b) { float d = a - b; return d < 0.01f && d > -0.01f; }

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

    // ── config / ini parsing ──────────────────────────────────────────────
    printf("[config] ini=%s\n", argc > 1 ? argv[1] : "(none supplied)");
    if (argc > 1) SetEnvironmentVariableA("RANDOVERLAY_INI", argv[1]);
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
    CHECK(cfg.emulatorProcs.find("rpcs3.exe") != std::string::npos, "RAC1 EmulatorProcesses has rpcs3.exe");
    CHECK(cfg.launcherExe.find("ArchipelagoLauncher.exe") != std::string::npos, "LauncherExe read");
    CHECK(cfg.fontFamily == "HandelGothic BT",  "FontFamily = HandelGothic BT");
    CHECK(cfg.fontFallback == "Bahnschrift",    "FontFallback = Bahnschrift");
    CHECK(cfg.clientComponent == "Ratchet & Clank Client",
          "RAC1 ClientComponent = Ratchet & Clank Client");
    CHECK(cfg.enabledPresets == "RAC1", "legacy INI falls back to ActivePreset as enabled set");

    // Existing installations preserve their INI during upgrades. Before
    // VulkanFontSize existed they only had WpfFontSize, which must not lower
    // the new Vulkan baseline.
    {
        char tmpP[MAX_PATH]; GetTempPathA(MAX_PATH, tmpP);
        std::string legacy = std::string(tmpP) + "randoverlay_legacy_font.ini";
        FILE* f = fopen(legacy.c_str(), "w");
        if (f) {
            fprintf(f, "[General]\nActivePreset=RAC1\n[Preset.RAC1]\nWpfFontSize=43\n");
            fclose(f);
        }
        SetEnvironmentVariableA("RANDOVERLAY_INI", legacy.c_str());
        RandOverlayConfig legacyCfg; legacyCfg.load();
        CHECK(legacyCfg.fontSize == 48,
              "legacy WpfFontSize does not override Vulkan 48px baseline");
        DeleteFileA(legacy.c_str());
        if (argc > 1) SetEnvironmentVariableA("RANDOVERLAY_INI", argv[1]);
    }

    // Preset-derived ClientComponent default (RAC3 preset, no explicit key)
    {
        char tmpP[MAX_PATH]; GetTempPathA(MAX_PATH, tmpP);
        std::string mini = std::string(tmpP) + "randoverlay_mini.ini";
        FILE* f = fopen(mini.c_str(), "w");
        if (f) {
            fprintf(f, "[General]\nActivePreset=RAC3\nEnabledPresets=RAC1,RAC2,RAC3\n");
            fclose(f);
        }
        SetEnvironmentVariableA("RANDOVERLAY_INI", mini.c_str());
        RandOverlayConfig c3; c3.load();
        CHECK(c3.clientComponent == "Ratchet and Clank 3 Client",
              "RAC3 default ClientComponent derived from preset");
        CHECK(c3.enabledPresets == "RAC1,RAC2,RAC3", "EnabledPresets list loaded");
        c3.load("RAC2");
        CHECK(c3.activePreset == "RAC2" && c3.clientComponent == "Ratchet & Clank 2 Client" &&
              c3.emulatorProcs.find("pcsx2") != std::string::npos,
              "runtime preset override reloads RAC2 configuration");
        DeleteFileA(mini.c_str());
        if (argc > 1) SetEnvironmentVariableA("RANDOVERLAY_INI", argv[1]); // restore
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
    char tmp[MAX_PATH]; GetTempPathA(MAX_PATH, tmp);
    std::string dir = std::string(tmp) + "randoverlay_test_logs";
    CreateDirectoryA(dir.c_str(), NULL);
    std::string logf = dir + "\\Launcher_unittest.txt";
    { FILE* f = fopen(logf.c_str(), "w"); if (f) { fprintf(f, "seed line ignored\n"); fclose(f); } }

    LogReader lr(dir); // seeds on the existing 1 line
    { FILE* f = fopen(logf.c_str(), "a"); if (f) { fprintf(f, "[Client at 12:00:00]: Ratchet found their Hydrodisplacer (RAC1)\n"); fclose(f); } }
    auto msgs = lr.poll();
    CHECK(!msgs.empty(), "poll() picks up the appended event line");
    if (!msgs.empty()) {
        printf("    parsed: \"%s\"\n", msgs.back().text.c_str());
        CHECK(msgs.back().text.find("found their") != std::string::npos, "message keeps 'found their'");
        CHECK(msgs.back().text.find("(RAC1)") == std::string::npos,      "parenthesized suffix stripped");
    }
    { FILE* f = fopen(logf.c_str(), "a"); if (f) { fprintf(f, "[Client at 12:00:01]: routine chatter line\n"); fclose(f); } }
    CHECK(lr.poll().empty(), "non-event chatter is ignored");

    DeleteFileA(logf.c_str());
    RemoveDirectoryA(dir.c_str());

    // ── Log selection parity (AHK/PS: any *.txt except Generate_/Server_) ─
    printf("[log_reader selection parity]\n");
    std::string dir2 = std::string(tmp) + "randoverlay_test_logs2";
    CreateDirectoryA(dir2.c_str(), NULL);
    std::string clientLog = dir2 + "\\RAC2Client_unittest.txt"; // non-Launcher_ name
    std::string genLog    = dir2 + "\\Generate_unittest.txt";
    { FILE* f = fopen(clientLog.c_str(), "w"); if (f) { fprintf(f, "seed\n"); fclose(f); } }
    Sleep(30); // ensure Generate_ has the NEWER write time
    { FILE* f = fopen(genLog.c_str(), "w"); if (f) { fprintf(f, "[Client at 1:00:00]: decoy found their trap (X)\n"); fclose(f); } }

    LogReader lr2(dir2);
    { FILE* f = fopen(clientLog.c_str(), "a"); if (f) { fprintf(f, "[Client at 1:00:01]: Ratchet found their Persuader (RAC2)\n"); fclose(f); } }
    auto msgs2 = lr2.poll();
    CHECK(!msgs2.empty(), "non-Launcher_ client log is tailed");
    if (!msgs2.empty())
        CHECK(msgs2.back().text.find("Persuader") != std::string::npos,
              "event came from client log, not the newer Generate_ decoy");

    DeleteFileA(clientLog.c_str());
    DeleteFileA(genLog.c_str());
    RemoveDirectoryA(dir2.c_str());

    // ── Font resolver ─────────────────────────────────────────────────────
    printf("[font_resolver]\n");
    std::string bahn = rofont::resolveFamilyToFile("Bahnschrift"); // ships with Win10/11
    CHECK(!bahn.empty() && GetFileAttributesA(bahn.c_str()) != INVALID_FILE_ATTRIBUTES,
          "Bahnschrift resolves to an existing file");
    if (!bahn.empty()) printf("    Bahnschrift -> %s\n", bahn.c_str());
    std::string handel = rofont::resolveFamilyToFile("HandelGothic BT");
    if (!handel.empty()) {
        CHECK(GetFileAttributesA(handel.c_str()) != INVALID_FILE_ATTRIBUTES,
              "HandelGothic BT resolves to an existing file");
        printf("    HandelGothic BT -> %s\n", handel.c_str());
    } else {
        printf("    (HandelGothic BT not installed on this device - fallback path will be used)\n");
    }
    CHECK(rofont::resolveFamilyToFile("Definitely Not A Font 123").empty(),
          "unknown family resolves to empty");
    CHECK(rofont::normalize("Handel Gothic BT") == "handelgothicbt", "normalize strips spaces/case");

    // ── Archipelago process check (informational — depends on live state) ─
    printf("[arch_client_check]\n");
    printf("    isArchipelagoRunning() = %s\n", roarch::isArchipelagoRunning() ? "true" : "false");

    printf("\n=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
