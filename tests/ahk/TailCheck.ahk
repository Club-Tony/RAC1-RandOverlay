#Requires AutoHotkey v1
#NoEnv
; Test-RandOverlay.ps1 starts this with /force, so parallel test runs never
; replace each other; Force only matters when it is launched by hand.
#SingleInstance, Force
#Warn All, StdOut
#Include %A_ScriptDir%\..\..\Lib\RandOverlayTail.ahk

; Runs the log tail contract cases through ArchTailRead against a log in the
; given scratch directory and prints one line per case to stdout. Usage:
;   AutoHotkey.exe /ErrorStdOut TailCheck.ahk <scratch-dir>
; Exit code: 0 all cases pass, 1 a case failed, 2 no scratch directory.

tcDir := A_Args.Length() >= 1 ? A_Args[1] : ""
if (tcDir = "" || !InStr(FileExist(tcDir), "D")) {
    FileAppend, % "ERROR scratch directory not found: " . tcDir . "`n", *
    ExitApp, 2
}
tcLog := tcDir . "\Client_tail.txt"
tcCases := 0
tcFailures := 0

TcWrite(tcLog, "seed one`r`nseed two`r`n")
tcCursor := ArchTailCursorAtEnd(tcLog)
FileGetSize, tcSize, %tcLog%
TcCheck("seeded at the end", tcCursor.offset = tcSize, "offset=" . tcCursor.offset)
TcExpect("unchanged after seeding", tcCursor, [])

tcFirst := "[Client at 1:00:00]: Ratchet found their Gold Bolt (Kerwan)"
TcAppend(tcLog, tcFirst . "`r`n")
TcExpect("appended line, CRLF stripped", tcCursor, [tcFirst])

TcAppend(tcLog, "[Client at 1:00:01]: Clank found")
TcExpect("a partial line is held back", tcCursor, [])
TcAppend(tcLog, " their Swingshot`n")
TcExpect("the completed line is read whole", tcCursor, ["[Client at 1:00:01]: Clank found their Swingshot"])
TcExpect("unchanged log", tcCursor, [])

TcWrite(tcLog, "[Client at 2:00:00]: short`n")
TcExpect("truncated to fewer bytes", tcCursor, ["[Client at 2:00:00]: short"], true)
TcAppend(tcLog, "[Client at 2:00:01]: next`n")
TcExpect("tailing resumes after a truncation", tcCursor, ["[Client at 2:00:01]: next"])

tcLong := "[Client at 3:00:00]: Ratchet found their "
Loop 200
    tcLong .= "x"
tcLong .= " (Somewhere)"
TcWrite(tcLog, tcLong . "`n")
TcExpect("rewritten larger with fewer lines", tcCursor, [tcLong], true)

; The case a line count misses: rewritten larger with MORE lines.
tcMany := []
tcManyText := ""
Loop 6 {
    tcMany.Push("[Client at 4:00:0" . A_Index . "]: line " . A_Index . " of a rewritten log padding padding")
    tcManyText .= tcMany[A_Index] . "`n"
}
TcWrite(tcLog, tcManyText)
TcExpect("rewritten larger with more lines", tcCursor, tcMany, true)

; Archipelago writes UTF-8 with a byte order mark.
tcBolt := "[Client at 5:00:00]: Ratchet found their " . Chr(0xD6) . "mega Bolt"
TcWrite(tcLog, tcBolt . "`n", "UTF-8")
TcExpect("UTF-8 decoded and the BOM dropped", tcCursor, [tcBolt], true)

; Archipelago keeps its log open for writing while the overlay reads it.
tcWriter := FileOpen(tcLog, "a", "UTF-8-RAW")
tcWriter.Write("[Client at 5:00:01]: while open`n")
tcHandle := tcWriter.__Handle ; reading the handle flushes the write buffer
TcExpect("read while the writer holds the file", tcCursor, ["[Client at 5:00:01]: while open"])
tcWriter.Close()

TcWrite(tcLog, "")
tcCursor := ArchTailCursorAtEnd(tcLog)
TcAppend(tcLog, "first line`n")
TcExpect("a log seeded empty is read from its start", tcCursor, ["first line"])

FileAppend, % "cases=" . tcCases . " failures=" . tcFailures . "`n", *
ExitApp, % tcFailures ? 1 : 0

TcWrite(path, text, encoding := "UTF-8-RAW") {
    tcwFile := FileOpen(path, "w", encoding)
    tcwFile.Write(text)
    tcwFile.Close()
}

TcAppend(path, text) {
    tcaFile := FileOpen(path, "a", "UTF-8-RAW")
    tcaFile.Write(text)
    tcaFile.Close()
}

; Polls once and fails unless exactly the expected lines came back.
TcExpect(name, cursor, expected, fromTop := false) {
    global tcLog
    tceLines := ArchTailRead(tcLog, cursor)
    tceSame := tceLines.Length() = expected.Length() && cursor.fromTop = fromTop
    tceGot := ""
    for tceIndex, tceLine in tceLines {
        tceGot .= (tceIndex > 1 ? "|" : "") . tceLine
        if (tceSame && !(tceLine == expected[tceIndex]))
            tceSame := false
    }
    TcCheck(name, tceSame, "got [" . tceGot . "] fromTop=" . cursor.fromTop)
}

TcCheck(name, passed, detail) {
    global tcCases, tcFailures
    tcCases += 1
    if (passed) {
        FileAppend, % "ok " . name . "`n", *
    } else {
        tcFailures += 1
        FileAppend, % "FAIL " . name . ": " . detail . "`n", *
    }
}
