; Shared singleton guard for standalone AutoHotkey v1 scripts.
; #SingleInstance is path-scoped, so junction aliases can otherwise double-run
; the same physical script. This uses the resolved file path as a named mutex.

EnsureScriptSingleton(mutexSource := "")
{
    global scriptSingletonMutexHandle

    if (mutexSource = "")
        mutexSource := ScriptSingletonResolvePath(A_ScriptFullPath)

    mutexName := "Local\AHK_ScriptSingleton_" . ScriptSingletonMutexId(mutexSource)
    scriptSingletonMutexHandle := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", mutexName, "Ptr")
    if (!scriptSingletonMutexHandle || A_LastError = 183)
    {
        if (scriptSingletonMutexHandle)
            DllCall("CloseHandle", "Ptr", scriptSingletonMutexHandle)
        ExitApp
    }
}

ScriptSingletonResolvePath(filePath)
{
    local fullPath, handle, capacityChars, finalPath

    fullPath := ScriptSingletonFullPath(filePath)
    handle := DllCall("CreateFile", "Str", fullPath, "UInt", 0, "UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 0x02000000, "Ptr", 0, "Ptr")
    if (!handle || handle = -1)
        return fullPath

    capacityChars := 32768
    VarSetCapacity(finalPath, capacityChars * 2, 0)
    len := DllCall("GetFinalPathNameByHandle", "Ptr", handle, "Str", finalPath, "UInt", capacityChars, "UInt", 0, "UInt")
    DllCall("CloseHandle", "Ptr", handle)

    if (len <= 0 || len >= capacityChars)
        return fullPath

    if (SubStr(finalPath, 1, 4) = "\\?\")
        finalPath := SubStr(finalPath, 5)

    return finalPath
}

ScriptSingletonFullPath(filePath)
{
    local capacityChars, fullPath, len

    capacityChars := 32768
    VarSetCapacity(fullPath, capacityChars * 2, 0)
    len := DllCall("GetFullPathName", "Str", filePath, "UInt", capacityChars, "Str", fullPath, "Ptr", 0, "UInt")
    if (len <= 0 || len >= capacityChars)
        return filePath
    return fullPath
}

ScriptSingletonMutexId(text)
{
    local lowered, clean

    StringLower, lowered, text
    clean := RegExReplace(lowered, "[^A-Za-z0-9_.-]", "_")
    if (StrLen(clean) > 220)
        clean := SubStr(clean, 1, 180) . "_" . ScriptSingletonChecksum(lowered)
    return clean
}

ScriptSingletonChecksum(text)
{
    local hash

    hash := 0
    Loop, Parse, text
        hash := Mod((hash * 131) + Asc(A_LoopField), 4294967291)
    return Format("{:08X}", hash)
}
