; Archipelago log tailing shared by RandOverlay.ahk and its test harness. The
; same tail contract is implemented by the PowerShell/WPF and Vulkan runtimes.
; A cursor holds the byte offset read up to, the file size at the last poll,
; and up to 64 bytes just before the offset (the anchor). A poll reads only the
; bytes after the offset and consumes only complete lines, so a line still being
; written is read whole on a later poll. A file smaller than at the last poll
; was truncated in place; one whose anchor bytes changed was rewritten and has
; already regrown past the offset. Both are read again from the top. Functions
; here read no globals, so they stay quiet under #Warn All.

; Returns a cursor at the end of the log at path, so what it already holds is
; not shown. A log that cannot be opened gets a cursor at the top.
ArchTailCursorAtEnd(path) {
    archTailCursor := {offset: 0, size: 0, anchor: "0:", fromTop: false}
    archTailFile := FileOpen(path, "r")
    if (!IsObject(archTailFile))
        return archTailCursor
    archTailCursor.offset := archTailFile.Length
    archTailCursor.size := archTailCursor.offset
    archTailCursor.anchor := ArchTailAnchor(archTailFile, archTailCursor.offset)
    archTailFile.Close()
    return archTailCursor
}

; Returns the complete lines added to the log since cursor, without their line
; breaks, and moves cursor past them. Sets cursor.fromTop when the log was read
; from the top. Returns no lines when the log cannot be opened.
ArchTailRead(path, cursor) {
    archTailLines := []
    cursor.fromTop := false
    archTailFile := FileOpen(path, "r")
    if (!IsObject(archTailFile))
        return archTailLines
    archTailSize := archTailFile.Length
    if (archTailSize = cursor.size) {
        archTailFile.Close()
        return archTailLines
    }

    archTailStart := cursor.offset
    if (archTailSize < cursor.size || ArchTailAnchor(archTailFile, archTailStart) != cursor.anchor) {
        archTailStart := 0
        cursor.fromTop := true
    }

    archTailLength := archTailSize - archTailStart
    VarSetCapacity(archTailBytes, archTailLength + 1, 0)
    archTailFile.Pos := archTailStart
    archTailConsumed := archTailLength > 0 ? archTailFile.RawRead(archTailBytes, archTailLength) : 0
    while (archTailConsumed > 0 && NumGet(archTailBytes, archTailConsumed - 1, "UChar") != 10)
        archTailConsumed -= 1

    ; Archipelago writes UTF-8 with a byte order mark.
    archTailSkip := 0
    if (archTailStart = 0 && archTailConsumed >= 3 && NumGet(archTailBytes, 0, "UChar") = 0xEF
        && NumGet(archTailBytes, 1, "UChar") = 0xBB && NumGet(archTailBytes, 2, "UChar") = 0xBF)
        archTailSkip := 3
    if (archTailConsumed > archTailSkip) {
        archTailText := StrGet(&archTailBytes + archTailSkip, archTailConsumed - archTailSkip, "UTF-8")
        archTailLines := StrSplit(archTailText, "`n", "`r")
        ; The text ends in a line break, so the last part is always empty.
        archTailLines.RemoveAt(archTailLines.Length())
    }

    cursor.offset := archTailStart + archTailConsumed
    cursor.size := archTailSize
    cursor.anchor := ArchTailAnchor(archTailFile, cursor.offset)
    archTailFile.Close()
    return archTailLines
}

; Returns the up to 64 bytes before offset as "<count>:<hex>". The count keeps
; it from ever looking numeric, which AutoHotkey would compare as a number.
ArchTailAnchor(file, offset) {
    archTailCount := offset < 64 ? offset : 64
    archTailHex := ""
    if (archTailCount > 0) {
        VarSetCapacity(archTailAnchorBytes, archTailCount, 0)
        file.Pos := offset - archTailCount
        archTailCount := file.RawRead(archTailAnchorBytes, archTailCount)
        Loop % archTailCount
            archTailHex .= Format("{:02X}", NumGet(archTailAnchorBytes, A_Index - 1, "UChar"))
    }
    return archTailCount . ":" . archTailHex
}
