#Requires AutoHotkey v1
#NoEnv
; Test-RandOverlay.ps1 starts this with /force, so parallel test runs never
; replace each other; Force only matters when it is launched by hand.
#SingleInstance, Force
#Warn All, StdOut
#Include %A_ScriptDir%\..\..\Lib\RandOverlayParse.ahk

; Runs every row of the shared Archipelago fixture through ArchFormatEvent and
; prints one line per row to stdout. Usage:
;   AutoHotkey.exe /ErrorStdOut ParseFixture.ahk [fixture.tsv]
; Exit code: 0 all rows match, 1 a row mismatched or was malformed, 2 no fixture.

fxPath := A_Args.Length() >= 1 ? A_Args[1] : A_ScriptDir . "\..\fixtures\archipelago-log-lines.tsv"
FileRead, fxContent, %fxPath%
if (ErrorLevel) {
    FileAppend, % "ERROR cannot read fixture: " . fxPath . "`n", *
    ExitApp, 2
}

fxRows := 0
fxFailures := 0
Loop, Parse, fxContent, `n, `r
{
    fxRow := A_LoopField
    if (fxRow = "" || SubStr(fxRow, 1, 1) = "#")
        continue

    fxRows += 1
    fxTab := InStr(fxRow, "`t", false, 0)
    if (!fxTab) {
        fxFailures += 1
        FileAppend, % "FAIL line " . A_Index . ": no tab`n", *
        continue
    }

    fxInput := SubStr(fxRow, 1, fxTab - 1)
    fxExpected := SubStr(fxRow, fxTab + 1)
    if (fxExpected == "<none>")
        fxExpected := ""
    fxActual := ArchFormatEvent(fxInput)
    if (fxActual == fxExpected) {
        FileAppend, % "ok line " . A_Index . "`n", *
    } else {
        fxFailures += 1
        FileAppend, % "FAIL line " . A_Index . ": expected [" . fxExpected . "] got [" . fxActual . "]`n", *
    }
}

FileAppend, % "rows=" . fxRows . " failures=" . fxFailures . "`n", *
ExitApp, % fxFailures ? 1 : 0
