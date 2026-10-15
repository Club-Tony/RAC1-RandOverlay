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

// Tails the newest Archipelago log under the tail contract shared with the AHK
// and PS+WPF runtimes. The reader holds the byte offset read up to, the file
// size at the last poll, and up to kAnchorBytes bytes just before the offset
// (the anchor). A poll reads only the bytes after the offset and consumes only
// complete lines, so a line still being written is read whole on a later poll.
// A file smaller than at the last poll was truncated in place; one whose anchor
// bytes changed was rewritten and has already regrown past the offset. Both are
// read again from the top. Only the last match is displayed, so that cannot
// flood the overlay. poll() runs on the present path, so its cost must not grow
// with the log: a whole-file re-read of a 10 MB log took ~33 ms per poll.
class LogReader {
public:
    explicit LogReader(const std::string& logDir = roplat::defaultArchipelagoLogDir())
        : logDir_(logDir), readOffset_(0), lastFileSize_(0) {
        findNewestLog();
        seedAtEnd();
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
            seedAtEnd();
        }

        if (currentLogFile_.empty()) return messages;

        // Cheap guard: nothing to read while the size is unchanged.
        std::error_code ec;
        uintmax_t fileSize = std::filesystem::file_size(currentLogFile_, ec);
        if (ec || (uint64_t)fileSize == lastFileSize_) return messages;
        const uint64_t size = (uint64_t)fileSize;

        std::ifstream file(currentLogFile_, std::ios::binary);
        if (!file.is_open()) return messages;

        uint64_t start = readOffset_;
        if (size < lastFileSize_ || readAnchor(file, start) != anchor_) start = 0;

        std::string bytes = readAt(file, start, size - start);
        size_t lastBreak = bytes.rfind('\n');
        size_t consumed = lastBreak == std::string::npos ? 0 : lastBreak + 1;

        size_t pos = (start == 0 && bytes.compare(0, 3, "\xEF\xBB\xBF") == 0) ? 3 : 0;
        while (pos < consumed) {
            size_t eol = bytes.find('\n', pos);
            std::string line = bytes.substr(pos, eol - pos);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            std::string msg = rolog::formatEvent(line);
            if (!msg.empty())
                messages.push_back({msg, roplat::monotonicMs()});
            pos = eol + 1;
        }

        readOffset_ = start + consumed;
        lastFileSize_ = size;
        anchor_ = readAnchor(file, readOffset_);
        return messages;
    }

private:
    static constexpr uint64_t kAnchorBytes = 64;

    std::string logDir_;
    std::string currentLogFile_;
    uint64_t readOffset_;
    uint64_t lastFileSize_;
    std::string anchor_;

    // Reads up to `count` bytes at `offset`; fewer at the end of the file.
    static std::string readAt(std::ifstream& file, uint64_t offset, uint64_t count) {
        std::string bytes((size_t)count, '\0');
        file.clear();
        file.seekg((std::streamoff)offset);
        file.read(&bytes[0], (std::streamsize)count);
        bytes.resize((size_t)file.gcount());
        return bytes;
    }

    static std::string readAnchor(std::ifstream& file, uint64_t offset) {
        uint64_t length = offset < kAnchorBytes ? offset : kAnchorBytes;
        return readAt(file, offset - length, length);
    }

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

    // Starts tailing at the end of the current log, so what it already holds
    // is not shown. A log that cannot be read is tailed from the top instead.
    void seedAtEnd() {
        readOffset_ = 0;
        lastFileSize_ = 0;
        anchor_.clear();

        if (currentLogFile_.empty()) return;

        std::ifstream file(currentLogFile_, std::ios::binary);
        if (!file.is_open()) return;

        std::error_code ec;
        uintmax_t size = std::filesystem::file_size(currentLogFile_, ec);
        if (ec) return;
        readOffset_ = lastFileSize_ = (uint64_t)size;
        anchor_ = readAnchor(file, readOffset_);
    }
};
