#pragma once
#include "platform.h"
#include <string>
#include <vector>
#include <fstream>
#include <cstdint>
#include <filesystem>

struct OverlayMessage {
    std::string text;
    uint64_t timestamp; // roplat::monotonicMs() when message was detected
};

namespace rolog {

// The Archipelago line contract shared with the AHK and PS+WPF runtimes and
// pinned by tests/fixtures/archipelago-log-lines.tsv at the repository root:
//   1. ^\[(FileLog|Client) at [^\]]+\]:\s*(.*)  - prefix is case-sensitive
//   2. shown only if the message contains one of the keywords below, compared
//      case-insensitively (checked before step 3)
//   3. a trailing location is removed with \s*\(.*\)\s*$ - from the FIRST '('
//      when the message ends in ')' - then spaces and tabs are trimmed
//   4. an empty result is not shown
// Returns the overlay text, or "" when the line is not shown.
inline std::string formatEvent(const std::string& line) {
    auto isSpace = [](char c) {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
    };

    size_t pos;
    if (line.compare(0, 12, "[FileLog at ") == 0)     pos = 12;
    else if (line.compare(0, 11, "[Client at ") == 0) pos = 11;
    else return "";
    size_t close = line.find(']', pos);
    if (close == std::string::npos || close == pos) return "";
    if (close + 1 >= line.size() || line[close + 1] != ':') return "";
    pos = close + 2;
    while (pos < line.size() && isSpace(line[pos])) pos++;
    std::string msg = line.substr(pos);

    std::string lower = msg;
    for (char& c : lower)
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    static const char* const keywords[] = {
        "test", "found their", "completed their goal", "congratulations",
        "released all remaining",
    };
    bool interesting = false;
    for (const char* k : keywords)
        if (lower.find(k) != std::string::npos) { interesting = true; break; }
    if (!interesting) return "";

    size_t end = msg.size();
    while (end > 0 && isSpace(msg[end - 1])) end--;
    size_t open = msg.find('(');
    if (end > 0 && msg[end - 1] == ')' && open != std::string::npos && open < end - 1) {
        while (open > 0 && isSpace(msg[open - 1])) open--;
        msg.erase(open);
    }

    size_t b = msg.find_first_not_of(" \t");
    if (b == std::string::npos) return "";
    size_t e = msg.find_last_not_of(" \t");
    return msg.substr(b, e - b + 1);
}

} // namespace rolog

class LogReader {
public:
    explicit LogReader(const std::string& logDir = roplat::defaultArchipelagoLogDir())
        : logDir_(logDir), lastLineCount_(0), lastFileSize_(0) {
        findNewestLog();
        seedLineCount();
    }

    // Which log file is currently being tailed (diagnostics).
    const std::string& currentLogFile() const { return currentLogFile_; }

    // Returns new messages since last check
    std::vector<OverlayMessage> poll() {
        std::vector<OverlayMessage> messages;

        // Check for newer log file
        std::string newest = findNewestLogPath();
        if (!newest.empty() && newest != currentLogFile_) {
            currentLogFile_ = newest;
            seedLineCount();
        }

        if (currentLogFile_.empty()) return messages;

        // Cheap guard: skip the full read unless the file changed size. A
        // smaller file means it was truncated in place (same name), which
        // must restart the scan rather than stall until it regrows past its
        // old length.
        std::error_code ec;
        uintmax_t fileSize = std::filesystem::file_size(currentLogFile_, ec);
        if (ec) return messages;

        if ((uint64_t)fileSize == lastFileSize_) return messages;
        bool truncated = (uint64_t)fileSize < lastFileSize_;
        lastFileSize_ = (uint64_t)fileSize;

        // Read file content
        std::ifstream file(currentLogFile_);
        if (!file.is_open()) return messages;

        std::vector<std::string> lines;
        std::string line;
        while (std::getline(file, line)) {
            // Strip \r if present
            if (!line.empty() && line.back() == '\r')
                line.pop_back();
            lines.push_back(line);
        }
        file.close();

        // Fewer lines than last time is the other face of a truncation: the
        // file was cut and has already regrown past its old size. Either way
        // every current line is new. Only the last match is displayed, so
        // rescanning a whole file cannot flood the overlay.
        if (truncated || (int)lines.size() < lastLineCount_) lastLineCount_ = 0;

        // Process new lines
        for (int i = lastLineCount_; i < (int)lines.size(); i++) {
            std::string msg = rolog::formatEvent(lines[i]);
            if (!msg.empty())
                messages.push_back({msg, roplat::monotonicMs()});
        }

        lastLineCount_ = (int)lines.size();
        return messages;
    }

private:
    std::string logDir_;
    std::string currentLogFile_;
    int lastLineCount_;
    uint64_t lastFileSize_;

    void findNewestLog() {
        currentLogFile_ = findNewestLogPath();
    }

    std::string findNewestLogPath() {
        // Parity with the AHK/PS runtimes: newest *.txt in the log dir,
        // excluding generator/server logs (Generate_*, Server_*). The extension
        // and prefix tests are case-insensitive to match the Windows shell
        // semantics the other two runtimes get for free.
        namespace fs = std::filesystem;
        std::error_code ec;
        fs::directory_iterator it(logDir_, ec);
        if (ec) return "";

        std::string newestFile;
        fs::file_time_type newestTime = fs::file_time_type::min();

        for (const auto& entry : it) {
            if (!entry.is_regular_file(ec) || ec) continue;

            const std::string name = entry.path().filename().string();
            if (roplat::toLower(entry.path().extension().string()) != ".txt") continue;
            if (roplat::startsWithNoCase(name, "Generate_") ||
                roplat::startsWithNoCase(name, "Server_"))
                continue;

            fs::file_time_type mtime = entry.last_write_time(ec);
            if (ec) continue;
            if (newestFile.empty() || mtime > newestTime) {
                newestTime = mtime;
                newestFile = entry.path().string();
            }
        }
        return newestFile;
    }

    void seedLineCount() {
        lastLineCount_ = 0;
        lastFileSize_ = 0;

        if (currentLogFile_.empty()) return;

        std::ifstream file(currentLogFile_);
        if (!file.is_open()) return;

        std::string line;
        while (std::getline(file, line))
            lastLineCount_++;
        file.close();

        std::error_code ec;
        uintmax_t size = std::filesystem::file_size(currentLogFile_, ec);
        if (!ec) lastFileSize_ = (uint64_t)size;
    }
};
