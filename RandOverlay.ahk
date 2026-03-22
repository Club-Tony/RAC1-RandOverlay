#Requires AutoHotkey v1
#NoEnv
#SingleInstance, Force
#Warn
SendMode Input
SetWorkingDir %A_ScriptDir%
SetTitleMatchMode, 2


; ── Configuration ──────────────────────────────────────────────────────────────
archLogDir          := "C:\ProgramData\Archipelago\logs"
archLauncherExe     := "C:\ProgramData\Archipelago\ArchipelagoLauncher.exe"
archDisplayMs       := 5000
archFontFamily      := "HandelGothic BT"
archFontFallback    := "Bahnschrift"
archFontSize        := 32
archVerticalPct     := 0.17
archBgColor         := "1E1E1E"
archFadeInMs        := 300
archFadeOutMs       := 500
archPollMs          := 1500
archRpcs3Process    := "rpcs3.exe"
archFadeStepMs      := 30

; ── State ──────────────────────────────────────────────────────────────────────
archLastFileSize    := 0
archLastLineCount   := 0
archCurrentLogFile  := ""
archOverlayEnabled  := true
archGuiHwnd         := 0
archGuiReady        := false
archTextHwnd        := 0
archBgBrush         := 0
archCtrlColors      := {}
archIsVisible       := false
archFadeDirection   := 0
archCurrentAlpha    := 0
; ── Resolve font ───────────────────────────────────────────────────────────────
; HandelGothic BT preferred; Bahnschrift fallback (ships with Windows 10/11)
archFont := archFontFamily

; ── Startup checks ─────────────────────────────────────────────────────────────
Process, Exist, ArchipelagoLauncher.exe
if (!ErrorLevel) {
    MsgBox, 4, Archipelago Overlay, Archipelago Launcher is not running. Launch it?
    IfMsgBox Yes
    {
        Run, %archLauncherExe%
        Sleep, 3000
    }
}

; Find newest log
archCurrentLogFile := ArchFindNewestLog()
if (archCurrentLogFile = "") {
    MsgBox, 48, Archipelago Overlay, No Archipelago log files found in %archLogDir%
    ExitApp
}

; Seed file size and line count (skip existing content)
FileGetSize, archLastFileSize, %archCurrentLogFile%
FileRead, seedContent, %archCurrentLogFile%
if (ErrorLevel) {
    archLastLineCount := 0
} else {
    seedLines := StrSplit(seedContent, "`n", "`r")
    while (seedLines.Length() > 0 && seedLines[seedLines.Length()] = "")
        seedLines.RemoveAt(seedLines.Length())
    archLastLineCount := seedLines.Length()
}
seedContent := ""
seedLines := ""

; ── Build GUI ──────────────────────────────────────────────────────────────────
OnMessage(0x0138, "ArchCTLColorStatic")

Gui, ArchOvl:New, +AlwaysOnTop +ToolWindow -Caption +E0x20 +HwndarchGuiHwnd
Gui, ArchOvl:Color, %archBgColor%
Gui, ArchOvl:Font, s%archFontSize%, %archFont%
Gui, ArchOvl:Margin, 12, 8
Gui, ArchOvl:Add, Text, vArchOvlText HwndarchTextHwnd Center w100,

archCtrlColors[archTextHwnd] := 0xD4D4D4

Gui, ArchOvl:Show, NoActivate Hide
WinSet, Transparent, 0, ahk_id %archGuiHwnd%
archGuiReady := true

OnExit("ArchCleanup")

; ── Timers ─────────────────────────────────────────────────────────────────────
SetTimer, ArchPollLog, %archPollMs%
SetTimer, ArchFadeStep, %archFadeStepMs%
SetTimer, ArchReassertTopmost, 2000

; Show startup test notification
Sleep, 500
ArchShowMessage("Archipelago Overlay ready - waiting for events", 0xA88060)
return

; ── Hotkeys ────────────────────────────────────────────────────────────────────
^!a::
    archOverlayEnabled := !archOverlayEnabled
    if (archOverlayEnabled) {
        ArchShowMessage("Overlay ON", 0xA88060)
        ; Override display timer to 1.5s for toggle feedback
        SetTimer, ArchHideAfterDelay, -1500
    } else {
        SetTimer, ArchHideAfterDelay, Off
        archFadeDirection := 0
        Gui, ArchOvl:Hide
        archIsVisible := false
        ToolTip, Overlay OFF, , , 4
        SetTimer, ArchClearToggleTip, -2000
    }
return

ArchClearToggleTip:
    ToolTip, , , , 4
return

^Esc::Reload

^!f::
    if (archFont = "HandelGothic BT") {
        archFont := "Bahnschrift"
    } else {
        archFont := "HandelGothic BT"
    }
    Gui, ArchOvl:Font, s%archFontSize%, %archFont%
    GuiControl, ArchOvl:Font, ArchOvlText
    ArchShowMessage("Font: " . archFont, 0xA88060)
    SetTimer, ArchHideAfterDelay, -1500
return

; ── Log polling ────────────────────────────────────────────────────────────────
ArchPollLog:
    newest := ArchFindNewestLog()
    if (newest != "" && newest != archCurrentLogFile) {
        ; #8 HIGH: Seed new log file instead of resetting to 0 (prevents message flood)
        archCurrentLogFile := newest
        FileGetSize, archLastFileSize, %archCurrentLogFile%
        FileRead, switchContent, %archCurrentLogFile%
        if (!ErrorLevel) {
            switchLines := StrSplit(switchContent, "`n", "`r")
            while (switchLines.Length() > 0 && switchLines[switchLines.Length()] = "")
                switchLines.RemoveAt(switchLines.Length())
            archLastLineCount := switchLines.Length()
        } else {
            archLastLineCount := 0
        }
        switchContent := ""
        switchLines := ""
    }
    if (archCurrentLogFile = "")
        return
    if (!FileExist(archCurrentLogFile))
        return

    ; Check file size first — skip read if unchanged
    FileGetSize, currentSize, %archCurrentLogFile%
    if (currentSize <= archLastFileSize)
        return
    archLastFileSize := currentSize

    ; File grew — read new content
    file := FileOpen(archCurrentLogFile, "r")
    if (!file)
        return
    rawContent := file.Read()
    file.Close()

    allLines := StrSplit(rawContent, "`n", "`r")
    ; Strip trailing empty elements from split
    while (allLines.Length() > 0 && allLines[allLines.Length()] = "")
        allLines.RemoveAt(allLines.Length())
    lineCount := allLines.Length()
    if (lineCount <= archLastLineCount)
        return

    latestMsg := ""
    latestColor := 0

    Loop % lineCount - archLastLineCount
    {
        idx := archLastLineCount + A_Index
        line := allLines[idx]
        parsed := ArchParseLine(line)
        if (parsed.text != "") {
            latestMsg := parsed.text
            latestColor := parsed.color
        }
    }

    archLastLineCount := lineCount

    if (latestMsg != "")
        ArchShowMessage(latestMsg, latestColor)
return

; ── Functions ──────────────────────────────────────────────────────────────────

ArchFindNewestLog() {
    global archLogDir

    newestFile := ""
    newestTime := ""

    Loop, Files, %archLogDir%\Launcher_*.txt
    {
        if (A_LoopFileTimeModified > newestTime) {
            newestTime := A_LoopFileTimeModified
            newestFile := A_LoopFileFullPath
        }
    }
    return newestFile
}

ArchParseLine(line) {
    result := {text: "", color: 0}

    if (!RegExMatch(line, "^\[(FileLog|Client) at [^\]]+\]:\s*(.*)", m))
        return result

    parsedMsg := m2

    ; RAC1 steel blue #7B9EC6 → BGR 0xA88060
    if (InStr(parsedMsg, "test"))
        colorRef := 0xA88060
    else if (InStr(parsedMsg, "found their"))
        colorRef := 0xA88060
    else if (InStr(parsedMsg, "completed their goal"))
        colorRef := 0xA88060
    else if (InStr(parsedMsg, "Congratulations"))
        colorRef := 0xA88060
    else if (InStr(parsedMsg, "released all remaining"))
        colorRef := 0xA88060
    else
        return result

    ; Strip parenthesized location info
    parsedMsg := Trim(RegExReplace(parsedMsg, "\s*\(.*\)\s*$", ""))
    result.text := parsedMsg
    result.color := colorRef
    return result
}

ArchShowMessage(text, colorRef) {
    global archOverlayEnabled, archGuiHwnd, archTextHwnd, archCtrlColors
    global archIsVisible, archFadeDirection, archCurrentAlpha, archDisplayMs

    if (!archOverlayEnabled)
        return

    archFadeDirection := 0
    SetTimer, ArchHideAfterDelay, Off

    ; Set wide first so text doesn't wrap, then shrink to fit
    GuiControl, ArchOvl:Move, ArchOvlText, w3000
    GuiControl, ArchOvl:, ArchOvlText, %text%

    ; Measure exact text width and resize control to match
    hdc := DllCall("GetDC", "Ptr", archTextHwnd, "Ptr")
    hFont := DllCall("SendMessage", "Ptr", archTextHwnd, "UInt", 0x0031, "Ptr", 0, "Ptr", 0, "Ptr")
    DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont)
    VarSetCapacity(SIZE, 8)
    DllCall("GetTextExtentPoint32W", "Ptr", hdc, "WStr", text, "Int", StrLen(text), "Ptr", &SIZE)
    textW := NumGet(SIZE, 0, "Int") + 4
    DllCall("ReleaseDC", "Ptr", archTextHwnd, "Ptr", hdc)
    GuiControl, ArchOvl:Move, ArchOvlText, w%textW%

    ; Set text color directly (no glow — matches RAC1 style)
    archCtrlColors[archTextHwnd] := colorRef

    Gui, ArchOvl:Show, NoActivate AutoSize
    ArchPositionOverlay()
    WinSet, AlwaysOnTop, On, ahk_id %archGuiHwnd%
    WinSet, Redraw,, ahk_id %archGuiHwnd%
    archIsVisible := true
    archFadeDirection := 1
    archCurrentAlpha := 0

    SetTimer, ArchHideAfterDelay, -%archDisplayMs%
}

ArchPositionOverlay() {
    global archGuiHwnd, archRpcs3Process, archVerticalPct, archTextHwnd

    rpcs3Win := WinExist("ahk_exe " . archRpcs3Process)
    if (rpcs3Win) {
        WinGetPos, wx, wy, ww, wh, ahk_id %rpcs3Win%
    } else {
        SysGet, MonArea, MonitorWorkArea
        wx := MonAreaLeft
        wy := MonAreaTop
        ww := MonAreaRight - MonAreaLeft
        wh := MonAreaBottom - MonAreaTop
    }

    ; Get overlay width after text was set
    WinGetPos,,, ow,, ahk_id %archGuiHwnd%
    if (ow <= 0)
        ow := 600

    ; Center horizontally, position vertically
    newX := wx + (ww // 2) - (ow // 2)
    newY := wy + Floor(wh * archVerticalPct)

    WinMove, ahk_id %archGuiHwnd%,, %newX%, %newY%
}

ArchReassertTopmost:
    if (archIsVisible)
        WinSet, AlwaysOnTop, On, ahk_id %archGuiHwnd%
return

ArchHideAfterDelay:
    archFadeDirection := -1
return

; ── Animation step timer ───────────────────────────────────────────────────────
ArchFadeStep:
    if (archFadeDirection = 0)
        return

    if (archFadeDirection = 1) {
        ; Fade in
        fadeInSteps := Floor(archFadeInMs / archFadeStepMs)
        if (fadeInSteps < 1)
            fadeInSteps := 1
        archCurrentAlpha += Floor(255 / fadeInSteps)
        if (archCurrentAlpha >= 255) {
            archCurrentAlpha := 255
            archFadeDirection := 0
        }
        WinSet, Transparent, %archCurrentAlpha%, ahk_id %archGuiHwnd%
    }
    else if (archFadeDirection = -1) {
        ; Fade out
        fadeOutSteps := Floor(archFadeOutMs / archFadeStepMs)
        if (fadeOutSteps < 1)
            fadeOutSteps := 1
        archCurrentAlpha -= Floor(255 / fadeOutSteps)
        if (archCurrentAlpha <= 0) {
            archCurrentAlpha := 0
            archFadeDirection := 0
            Gui, ArchOvl:Hide
            archIsVisible := false
        }
        WinSet, Transparent, %archCurrentAlpha%, ahk_id %archGuiHwnd%
    }
return

ArchCleanup() {
    global archBgBrush
    if (archBgBrush)
        DllCall("DeleteObject", "Ptr", archBgBrush)
}

; ── WM_CTLCOLORSTATIC handler ──────────────────────────────────────────────────
ArchCTLColorStatic(wParam, lParam, msg, hwnd) {
    global archCtrlColors, archBgBrush, archGuiHwnd

    if (hwnd != archGuiHwnd)
        return

    bgColorRef := 0x1E1E1E
    DllCall("SetBkColor", "Ptr", wParam, "UInt", bgColorRef)

    if (archCtrlColors.HasKey(lParam))
        DllCall("SetTextColor", "Ptr", wParam, "UInt", archCtrlColors[lParam])

    if (!archBgBrush)
        archBgBrush := DllCall("CreateSolidBrush", "UInt", bgColorRef, "Ptr")

    return archBgBrush
}
