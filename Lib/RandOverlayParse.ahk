; Archipelago log-line parsing shared by RandOverlay.ahk and its fixture test.
; The same contract is implemented by the PowerShell/WPF and Vulkan runtimes and
; pinned by tests/fixtures/archipelago-log-lines.tsv. Functions here read no
; globals, so they stay quiet under #Warn All.

; Returns the overlay text for one client log line, or "" when it is not shown.
;   1. The "[FileLog at ...]:" / "[Client at ...]:" prefix is case-sensitive.
;   2. The message must contain a keyword. InStr compares A-Z case-insensitively
;      under the default StringCaseSense Off, which the overlay never changes.
;   3. A trailing location is cut from the first "(" when the message ends in
;      ")", then spaces and tabs are trimmed.
;   4. Nothing left means nothing shown.
ArchFormatEvent(line) {
    if (!RegExMatch(line, "^\[(FileLog|Client) at [^\]]+\]:\s*(.*)", archFormatMatch))
        return ""

    archFormatMsg := archFormatMatch2
    archFormatShown := false
    for archFormatIndex, archFormatKeyword in ["test", "found their", "completed their goal", "Congratulations", "released all remaining"] {
        if (InStr(archFormatMsg, archFormatKeyword)) {
            archFormatShown := true
            break
        }
    }
    if (!archFormatShown)
        return ""

    return Trim(RegExReplace(archFormatMsg, "\s*\(.*\)\s*$", ""))
}
