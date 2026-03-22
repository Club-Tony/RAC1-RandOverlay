#pragma once
#include <string>
#include <vector>
#include <fstream>
#include <windows.h>
#include <regex>

struct OverlayMessage {
    std::string text;
    DWORD timestamp; // GetTickCount() when message was detected
};

class LogReader {
public:
    LogReader() : lastLineCount_(0), lastFileSize_(0) {
        logDir_ = "C:\\ProgramData\\Archipelago\\logs";
        findNewestLog();
        seedLineCount();
    }

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

        // Check file size first
        HANDLE hFile = CreateFileA(currentLogFile_.c_str(), GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile == INVALID_HANDLE_VALUE) return messages;

        DWORD fileSize = GetFileSize(hFile, NULL);
        CloseHandle(hFile);

        if (fileSize <= lastFileSize_) return messages;
        lastFileSize_ = fileSize;

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
                messages.push_back({msg, GetTickCount()});
            }
        }

        lastLineCount_ = (int)lines.size();
        return messages;
    }

private:
    std::string logDir_;
    std::string currentLogFile_;
    int lastLineCount_;
    DWORD lastFileSize_;

    void findNewestLog() {
        currentLogFile_ = findNewestLogPath();
    }

    std::string findNewestLogPath() {
        WIN32_FIND_DATAA fd;
        std::string pattern = logDir_ + "\\Launcher_*.txt";
        HANDLE hFind = FindFirstFileA(pattern.c_str(), &fd);
        if (hFind == INVALID_HANDLE_VALUE) return "";

        std::string newestFile;
        FILETIME newestTime = {0, 0};

        do {
            if (CompareFileTime(&fd.ftLastWriteTime, &newestTime) > 0) {
                newestTime = fd.ftLastWriteTime;
                newestFile = logDir_ + "\\" + fd.cFileName;
            }
        } while (FindNextFileA(hFind, &fd));

        FindClose(hFind);
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

        HANDLE hFile = CreateFileA(currentLogFile_.c_str(), GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile != INVALID_HANDLE_VALUE) {
            lastFileSize_ = GetFileSize(hFile, NULL);
            CloseHandle(hFile);
        }
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
