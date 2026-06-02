#Requires AutoHotkey v1
#NoEnv
#SingleInstance, Force
#Include %A_ScriptDir%\Lib\ScriptSingleton.ahk
EnsureScriptSingleton()
#Warn
SendMode Input
SetWorkingDir %A_ScriptDir%
SetTitleMatchMode, 2


; ── Configuration ──────────────────────────────────────────────────────────────
archSelfTest        := false
archConfigFile      := A_ScriptDir . "\RandOverlay.ini"
archConfigWarning   := ""
archDefaultPreset   := "RAC1"
archActivePreset    := "RAC1"
archPresetDisplayName := "Ratchet & Clank 1"
archLogDir          := "C:\ProgramData\Archipelago\logs"
archLauncherExe     := "C:\ProgramData\Archipelago\ArchipelagoLauncher.exe"
archDisplayMs       := 5000
archFontFamily      := "HandelGothic BT"
archFontFallback    := "Bahnschrift"
archFontSize        := 32
archVerticalPct     := 0.17
archBgColor         := "1E1E1E"
archBgColorBgr      := 0x1E1E1E
archOverlayColorRgb := "80A0D0"
archOverlayColorBgr := 0xD0A080
archFadeInMs        := 300
archFadeOutMs       := 500
archPollMs          := 1500
archEmulatorProcesses := ["rpcs3.exe"]
archFadeStepMs      := 30
ArchParseArgs()
ArchLoadConfig()
ArchApplySelfTestOverrides()

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
archBorderlessHwnd  := 0
archOriginalStyle   := 0
archOriginalExStyle := 0
archOriginalRect    := {x: 0, y: 0, w: 0, h: 0}
; ── Resolve font ───────────────────────────────────────────────────────────────
; HandelGothic BT preferred; Bahnschrift fallback (ships with Windows 10/11)
archFont := archFontFamily

; ── Startup checks ─────────────────────────────────────────────────────────────
Process, Exist, ArchipelagoLauncher.exe
archLauncherFound := ErrorLevel
if (!archLauncherFound) {
    ; Also check for any Archipelago client window (game-specific or text)
    SetTitleMatchMode, RegEx
    archLauncherFound := WinExist("Archipelago.*Client")
    SetTitleMatchMode, 2
}
if (!archLauncherFound && !archSelfTest) {
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
if (archConfigWarning != "")
    ArchShowMessage(archConfigWarning, archOverlayColorBgr)
else
    ArchShowMessage("Archipelago Overlay ready - waiting for events", archOverlayColorBgr)
if (archSelfTest)
    SetTimer, ArchSelfTestExit, -750
return

; ── Hotkeys ────────────────────────────────────────────────────────────────────
^!a::
    archOverlayEnabled := !archOverlayEnabled
    if (archOverlayEnabled) {
        ArchShowMessage("Overlay ON", archOverlayColorBgr)
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

^!b::
    ; Toggle borderless fullscreen on the emulator window
    ; Prevents PCSX2's Direct Flip/iFlip from bypassing DWM composition
    if (archBorderlessHwnd) {
        ; Restore original window style
        WinSet, Style, %archOriginalStyle%, ahk_id %archBorderlessHwnd%
        WinSet, ExStyle, %archOriginalExStyle%, ahk_id %archBorderlessHwnd%
        archBorderRestoreX := archOriginalRect.x, archBorderRestoreY := archOriginalRect.y
        archBorderRestoreW := archOriginalRect.w, archBorderRestoreH := archOriginalRect.h
        WinMove, ahk_id %archBorderlessHwnd%,, %archBorderRestoreX%, %archBorderRestoreY%, %archBorderRestoreW%, %archBorderRestoreH%
        archBorderlessHwnd := 0
        ArchShowMessage("Borderless OFF - restored window", archOverlayColorBgr)
        SetTimer, ArchHideAfterDelay, -1500
        return
    }
    ; Find emulator window
    archBorderHwnd := 0
    for archBorderIndex, archBorderProc in archEmulatorProcesses {
        archBorderHwnd := WinExist("ahk_exe " . archBorderProc)
        if (archBorderHwnd)
            break
    }
    if (!archBorderHwnd) {
        ArchShowMessage("No emulator window found", archOverlayColorBgr)
        SetTimer, ArchHideAfterDelay, -1500
        return
    }
    ; Save original state
    WinGet, archBorderOrigStyle, Style, ahk_id %archBorderHwnd%
    WinGet, archBorderOrigExStyle, ExStyle, ahk_id %archBorderHwnd%
    WinGetPos, archBorderOrigX, archBorderOrigY, archBorderOrigW, archBorderOrigH, ahk_id %archBorderHwnd%
    archOriginalStyle := archBorderOrigStyle
    archOriginalExStyle := archBorderOrigExStyle
    archOriginalRect := {x: archBorderOrigX, y: archBorderOrigY, w: archBorderOrigW, h: archBorderOrigH}
    archBorderlessHwnd := archBorderHwnd
    ; Strip window chrome (WS_CAPTION=0xC00000, WS_THICKFRAME=0x40000)
    archBorderNewStyle := archBorderOrigStyle & ~0x00C00000 & ~0x00040000
    WinSet, Style, %archBorderNewStyle%, ahk_id %archBorderHwnd%
    ; Find which monitor the emulator is on and fill it
    SysGet, archBorderMonitorCount, MonitorCount
    Loop, %archBorderMonitorCount% {
        SysGet, archBorderMonitor, Monitor, %A_Index%
        archBorderMidX := archBorderOrigX + (archBorderOrigW // 2)
        archBorderMidY := archBorderOrigY + (archBorderOrigH // 2)
        if (archBorderMidX >= archBorderMonitorLeft && archBorderMidX < archBorderMonitorRight && archBorderMidY >= archBorderMonitorTop && archBorderMidY < archBorderMonitorBottom) {
            archBorderMonitorW := archBorderMonitorRight - archBorderMonitorLeft
            archBorderMonitorH := archBorderMonitorBottom - archBorderMonitorTop
            WinMove, ahk_id %archBorderHwnd%,, %archBorderMonitorLeft%, %archBorderMonitorTop%, %archBorderMonitorW%, %archBorderMonitorH%
            break
        }
    }
    ArchShowMessage("Borderless ON", archOverlayColorBgr)
    SetTimer, ArchHideAfterDelay, -1500
return

^!f::
    if (archFont = archFontFamily) {
        archFont := archFontFallback
    } else {
        archFont := archFontFamily
    }
    Gui, ArchOvl:Font, s%archFontSize%, %archFont%
    GuiControl, ArchOvl:Font, ArchOvlText
    ArchShowMessage("Font: " . archFont, archOverlayColorBgr)
    SetTimer, ArchHideAfterDelay, -1500
return

; ── Log polling ────────────────────────────────────────────────────────────────
ArchPollLog:
    archPollNewest := ArchFindNewestLog()
    if (archPollNewest != "" && archPollNewest != archCurrentLogFile) {
        ; #8 HIGH: Seed new log file instead of resetting to 0 (prevents message flood)
        archCurrentLogFile := archPollNewest
        FileGetSize, archLastFileSize, %archCurrentLogFile%
        FileRead, archPollSwitchContent, %archCurrentLogFile%
        if (!ErrorLevel) {
            archPollSwitchLines := StrSplit(archPollSwitchContent, "`n", "`r")
            while (archPollSwitchLines.Length() > 0 && archPollSwitchLines[archPollSwitchLines.Length()] = "")
                archPollSwitchLines.RemoveAt(archPollSwitchLines.Length())
            archLastLineCount := archPollSwitchLines.Length()
        } else {
            archLastLineCount := 0
        }
        archPollSwitchContent := ""
        archPollSwitchLines := ""
    }
    if (archCurrentLogFile = "")
        return
    if (!FileExist(archCurrentLogFile))
        return

    ; Check file size first — skip read if unchanged
    FileGetSize, archPollCurrentSize, %archCurrentLogFile%
    if (archPollCurrentSize <= archLastFileSize)
        return
    archLastFileSize := archPollCurrentSize

    ; File grew — read new content
    archPollFile := FileOpen(archCurrentLogFile, "r")
    if (!archPollFile)
        return
    archPollRawContent := archPollFile.Read()
    archPollFile.Close()

    archPollAllLines := StrSplit(archPollRawContent, "`n", "`r")
    ; Strip trailing empty elements from split
    while (archPollAllLines.Length() > 0 && archPollAllLines[archPollAllLines.Length()] = "")
        archPollAllLines.RemoveAt(archPollAllLines.Length())
    archPollLineCount := archPollAllLines.Length()
    if (archPollLineCount <= archLastLineCount)
        return

    archPollLatestMsg := ""
    archPollLatestColor := 0

    Loop % archPollLineCount - archLastLineCount
    {
        archPollIndex := archLastLineCount + A_Index
        archPollLine := archPollAllLines[archPollIndex]
        archPollParsed := ArchParseLine(archPollLine)
        if (archPollParsed.text != "") {
            archPollLatestMsg := archPollParsed.text
            archPollLatestColor := archPollParsed.color
        }
    }

    archLastLineCount := archPollLineCount

    if (archPollLatestMsg != "")
        ArchShowMessage(archPollLatestMsg, archPollLatestColor)
return

; ── Functions ──────────────────────────────────────────────────────────────────

ArchFindNewestLog() {
    global archLogDir

    newestFile := ""
    newestTime := ""

    Loop, Files, %archLogDir%\*.txt
    {
        if (SubStr(A_LoopFileName, 1, 9) = "Generate_" || SubStr(A_LoopFileName, 1, 7) = "Server_")
            continue
        if (A_LoopFileTimeModified > newestTime) {
            newestTime := A_LoopFileTimeModified
            newestFile := A_LoopFileFullPath
        }
    }
    return newestFile
}

ArchParseArgs() {
    global archSelfTest

    for archArgIndex, archArg in A_Args {
        if (archArg = "--self-test")
            archSelfTest := true
    }
}

ArchApplySelfTestOverrides() {
    global archSelfTest, archLogDir

    if (!archSelfTest)
        return

    EnvGet, archSelfTestLogDir, RANDO_OVERLAY_TEST_LOGDIR
    if (archSelfTestLogDir != "")
        archLogDir := archSelfTestLogDir
}

ArchLoadConfig() {
    global archConfigFile, archConfigWarning, archDefaultPreset, archActivePreset, archPresetDisplayName
    global archLogDir, archLauncherExe, archDisplayMs, archFontFamily, archFontFallback, archFontSize
    global archVerticalPct, archBgColor, archBgColorBgr, archOverlayColorRgb, archOverlayColorBgr
    global archFadeInMs, archFadeOutMs, archPollMs, archEmulatorProcesses

    if (!FileExist(archConfigFile)) {
        ArchSetConfigWarning("RandOverlay.ini not found; using built-in RAC1 defaults.")
        return
    }

    selectedPreset := ArchIniRead("General", "ActivePreset", archDefaultPreset)
    selectedPreset := Trim(selectedPreset)
    StringUpper, selectedPreset, selectedPreset
    if (!ArchIsKnownPreset(selectedPreset)) {
        ArchSetConfigWarning("Unknown ActivePreset '" . selectedPreset . "'; using RAC1 defaults.")
        selectedPreset := archDefaultPreset
    }
    archActivePreset := selectedPreset

    presetSection := "Preset." . archActivePreset
    defaultEmulators := ArchDefaultEmulatorsForPreset(archActivePreset)
    defaultDisplayName := ArchDefaultDisplayNameForPreset(archActivePreset)

    archLogDir := ArchIniRead("General", "LogDir", archLogDir)
    archLauncherExe := ArchIniRead("General", "LauncherExe", archLauncherExe)
    archDisplayMs := ArchIniReadInt("General", "DisplayMs", archDisplayMs, 1)
    archPollMs := ArchIniReadInt("General", "PollMs", archPollMs, 1)
    archFadeInMs := ArchIniReadInt("General", "FadeInMs", archFadeInMs, 0)
    archFadeOutMs := ArchIniReadInt("General", "FadeOutMs", archFadeOutMs, 0)

    archPresetDisplayName := ArchIniRead(presetSection, "DisplayName", defaultDisplayName)
    archEmulatorProcesses := ArchCsvToArray(ArchIniRead(presetSection, "EmulatorProcesses", defaultEmulators), ArchCsvToArray(defaultEmulators, []))
    archOverlayColorRgb := ArchNormalizeRgbHex(ArchIniRead(presetSection, "OverlayColor", archOverlayColorRgb), archOverlayColorRgb)
    archBgColor := ArchNormalizeRgbHex(ArchIniRead(presetSection, "BackgroundColor", archBgColor), archBgColor)
    archVerticalPct := ArchIniReadFloat(presetSection, "VerticalPercent", archVerticalPct)
    archFontFamily := ArchIniRead(presetSection, "FontFamily", archFontFamily)
    archFontFallback := ArchIniRead(presetSection, "FontFallback", archFontFallback)
    archFontSize := ArchIniReadInt(presetSection, "AhkFontSize", archFontSize, 1)

    archOverlayColorBgr := ArchRgbHexToBgr(archOverlayColorRgb, archOverlayColorBgr)
    archBgColorBgr := ArchRgbHexToBgr(archBgColor, archBgColorBgr)
}

ArchIniRead(section, key, defaultValue) {
    global archConfigFile

    IniRead, value, %archConfigFile%, %section%, %key%, %defaultValue%
    value := Trim(value)
    if (value = "" || value = "ERROR")
        return defaultValue
    return value
}

ArchIniReadInt(section, key, defaultValue, minValue := "") {
    value := ArchIniRead(section, key, defaultValue)
    if (RegExMatch(value, "^-?\d+$")) {
        value += 0
        if (minValue = "" || value >= minValue)
            return value
    }
    ArchSetConfigWarning("Invalid " . section . "." . key . "; using default.")
    return defaultValue
}

ArchIniReadFloat(section, key, defaultValue) {
    value := ArchIniRead(section, key, defaultValue)
    if (RegExMatch(value, "^-?\d+(\.\d+)?$"))
        return value + 0.0
    ArchSetConfigWarning("Invalid " . section . "." . key . "; using default.")
    return defaultValue
}

ArchSetConfigWarning(message) {
    global archConfigWarning
    if (archConfigWarning = "")
        archConfigWarning := message
}

ArchIsKnownPreset(preset) {
    return preset = "RAC1" || preset = "RAC2" || preset = "RAC3"
}

ArchDefaultDisplayNameForPreset(preset) {
    if (preset = "RAC2")
        return "Ratchet & Clank 2"
    if (preset = "RAC3")
        return "Ratchet & Clank 3"
    return "Ratchet & Clank 1"
}

ArchDefaultEmulatorsForPreset(preset) {
    if (preset = "RAC2" || preset = "RAC3")
        return "pcsx2-qt.exe,pcsx2.exe"
    return "rpcs3.exe"
}

ArchCsvToArray(csv, fallback := "") {
    result := []
    parts := StrSplit(csv, ",")
    for archCsvIndex, archCsvItem in parts {
        archCsvItem := Trim(archCsvItem)
        if (archCsvItem = "")
            continue
        if (!RegExMatch(archCsvItem, "i)\.exe$"))
            archCsvItem .= ".exe"
        result.Push(archCsvItem)
    }
    if (result.Length() = 0 && IsObject(fallback))
        return fallback
    return result
}

ArchNormalizeRgbHex(value, defaultValue) {
    value := Trim(value)
    if (SubStr(value, 1, 1) = "#")
        value := SubStr(value, 2)
    if (RegExMatch(value, "i)^[0-9a-f]{6}$"))
        return value
    if (defaultValue != "")
        ArchSetConfigWarning("Invalid color value; using default.")
    if (SubStr(defaultValue, 1, 1) = "#")
        return SubStr(defaultValue, 2)
    return defaultValue
}

ArchRgbHexToBgr(hexValue, defaultValue) {
    hexValue := ArchNormalizeRgbHex(hexValue, "")
    if (hexValue = "")
        return defaultValue
    r := "0x" . SubStr(hexValue, 1, 2)
    g := "0x" . SubStr(hexValue, 3, 2)
    b := "0x" . SubStr(hexValue, 5, 2)
    return ((b + 0) << 16) | ((g + 0) << 8) | (r + 0)
}

ArchParseLine(line) {
    global archOverlayColorBgr

    result := {text: "", color: 0}

    if (!RegExMatch(line, "^\[(FileLog|Client) at [^\]]+\]:\s*(.*)", m))
        return result

    parsedMsg := m2

    ; Config colors are RGB hex; Win32 text colors use BGR COLORREF.
    if (InStr(parsedMsg, "test"))
        colorRef := archOverlayColorBgr
    else if (InStr(parsedMsg, "found their"))
        colorRef := archOverlayColorBgr
    else if (InStr(parsedMsg, "completed their goal"))
        colorRef := archOverlayColorBgr
    else if (InStr(parsedMsg, "Congratulations"))
        colorRef := archOverlayColorBgr
    else if (InStr(parsedMsg, "released all remaining"))
        colorRef := archOverlayColorBgr
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
    global archGuiHwnd, archEmulatorProcesses, archVerticalPct, archTextHwnd

    archPositionEmuWin := 0
    for archPositionIndex, archPositionProc in archEmulatorProcesses {
        archPositionEmuWin := WinExist("ahk_exe " . archPositionProc)
        if (archPositionEmuWin)
            break
    }
    if (archPositionEmuWin) {
        WinGetPos, archPositionWindowX, archPositionWindowY, archPositionWindowW, archPositionWindowH, ahk_id %archPositionEmuWin%
    } else {
        SysGet, MonArea, MonitorWorkArea
        archPositionWindowX := MonAreaLeft
        archPositionWindowY := MonAreaTop
        archPositionWindowW := MonAreaRight - MonAreaLeft
        archPositionWindowH := MonAreaBottom - MonAreaTop
    }

    ; Get overlay width after text was set
    WinGetPos,,, archPositionOverlayW,, ahk_id %archGuiHwnd%
    if (archPositionOverlayW <= 0)
        archPositionOverlayW := 600

    ; Center horizontally, position vertically
    archPositionNewX := archPositionWindowX + (archPositionWindowW // 2) - (archPositionOverlayW // 2)
    archPositionNewY := archPositionWindowY + Floor(archPositionWindowH * archVerticalPct)

    WinMove, ahk_id %archGuiHwnd%,, %archPositionNewX%, %archPositionNewY%
}

ArchReassertTopmost:
    if (archIsVisible)
        WinSet, AlwaysOnTop, On, ahk_id %archGuiHwnd%
return

ArchSelfTestExit:
    ExitApp, 0
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
    global archCtrlColors, archBgBrush, archGuiHwnd, archBgColorBgr

    if (hwnd != archGuiHwnd)
        return

    bgColorRef := archBgColorBgr
    DllCall("SetBkColor", "Ptr", wParam, "UInt", bgColorRef)

    if (archCtrlColors.HasKey(lParam))
        DllCall("SetTextColor", "Ptr", wParam, "UInt", archCtrlColors[lParam])

    if (!archBgBrush)
        archBgBrush := DllCall("CreateSolidBrush", "UInt", bgColorRef, "Ptr")

    return archBgBrush
}
