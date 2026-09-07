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

        // Cheap guard: skip the full read unless the file actually grew.
        std::error_code ec;
        uintmax_t fileSize = std::filesystem::file_size(currentLogFile_, ec);
        if (ec) return messages;

        if (fileSize <= lastFileSize_) return messages;
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

        if ((int)lines.size() <= lastLineCount_) return messages;

        // Process new lines
        for (int i = lastLineCount_; i < (int)lines.size(); i++) {
            std::string msg = parseLine(lines[i]);
            if (!msg.empty()) {
                // Strip parenthesized location info
                size_t parenPos = msg.rfind('(');
                if (parenPos != std::string::npos && msg.back() == ')') {
                    msg = msg.substr(0, parenPos);
                    // Trim trailing whitespace
                    while (!msg.empty() && msg.back() == ' ')
                        msg.pop_back();
                }
                messages.push_back({msg, roplat::monotonicMs()});
            }
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

    std::string parseLine(const std::string& line) {
        // Match [FileLog at ...]: message or [Client at ...]: message
        size_t bracketEnd = line.find("]: ");
        if (bracketEnd == std::string::npos) return "";
        if (line[0] != '[') return "";

        // Check prefix is FileLog or Client
        if (line.find("[FileLog at ") != 0 && line.find("[Client at ") != 0)
            return "";

        std::string msg = line.substr(bracketEnd + 3);

        // Interest filter
        if (msg.find("test") != std::string::npos ||
            msg.find("found their") != std::string::npos ||
            msg.find("completed their goal") != std::string::npos ||
            msg.find("Congratulations") != std::string::npos ||
            msg.find("released all remaining") != std::string::npos) {
            return msg;
        }

        return "";
    }
};
