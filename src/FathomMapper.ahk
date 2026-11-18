; FathomMapper
; Copyright (C) 2026 Akamiechie
; Original program created by Akamiechie
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published
; by the Free Software Foundation; version 2.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;
; You should have received a copy of the GNU General Public License
; along with this program; if not, write to the Free Software
; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
; MA 02110-1301 USA.
;
; See the LICENSE.txt file for details.

#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "%A_ScriptDir%\OCR.ahk"

CoordMode "Pixel", "Screen"

DllCall("Winmm\timeBeginPeriod", "UInt", 1)

recording := false
finished := false
reading := false

points := []
markers := []

lastX := ""
lastZ := ""

rateCount := 0
rateStart := A_TickCount
failedReads := 0

hudWidth := 220
hudHeight := 45
hudX := A_ScreenWidth - hudWidth
hudY := A_ScreenHeight - hudHeight - 5

mapFolder := A_ScriptDir "\FathomMaps"
mapPath := ""

settingsFolder := A_ScriptDir "\FathomSettings"

autosavePath := mapFolder "\autosave.json"
autosaveInterval := 30000
dirty := false
lastSave := ""
autosaveFailures := 0
busy := false
mappingStarted := false
startNote := ""

segment := 0
pendingUnpause := false

keybindPath := settingsFolder "\settings.ini"
keybindActions := ["start", "rebuild", "exit", "menu", "toggle", "finish", "clear", "pin"]
keybindGroups := Map(
    "start", "start",
    "rebuild", "start",
    "exit", "start",
    "menu", "start",
    "toggle", "session",
    "finish", "session",
    "clear", "session",
    "pin", "session"
)
keybindLabels := Map(
    "start", "Start screen: start mapping",
    "rebuild", "Start screen: turn data file into map",
    "exit", "Start screen: close program",
    "menu", "Start screen: change keybinds",
    "toggle", "Mapping: pause / resume",
    "finish", "Mapping: finish and create map",
    "clear", "Mapping: clear map",
    "pin", "Mapping: add named pin"
)
keybindDefaults := Map(
    "start", "F1",
    "rebuild", "F2",
    "exit", "F3",
    "menu", "F4",
    "toggle", "F1",
    "finish", "F2",
    "clear", "F3",
    "pin", "F4"
)
keybindCallbacks := Map(
    "start", (*) => ToggleRecording(),
    "rebuild", (*) => RebuildMap(),
    "exit", (*) => ExitProgram(),
    "menu", (*) => OpenKeybindMenu(),
    "toggle", (*) => ToggleRecording(),
    "finish", (*) => FinishMapping(),
    "clear", (*) => ResetMapping(),
    "pin", (*) => AddPin()
)
keybinds := Map()
boundKeys := []
keybindGui := ""
keybindControls := Map()

OnExit(Cleanup)

LoadKeybinds()
ApplyKeybinds()

CheckForAutosave()

; Shows the start screen if no session is loaded.
if !HasMappingStarted()
    BeginStartScreen()

; Stops timers and autosaves unfinished work on exit.
Cleanup(*) {
    global finished, dirty, autosavePath

    SetTimer(ReadCoordinates, 0)
    SetTimer(UpdateStatus, 0)
    SetTimer(AutoSave, 0)
    SetTimer(ShowStartScreen, 0)

    if (!finished && dirty) {
        try {
            SaveSession(autosavePath)
        } catch {
        }
    }

    DllCall("Winmm\timeEndPeriod", "UInt", 1)
    ToolTip()
}

; Starts or pauses recording, tracking path segments.
ToggleRecording() {
    global recording, finished, points, markers
    global rateCount, rateStart, lastX, lastZ, dirty
    global autosaveInterval, lastSave, busy, mappingStarted
    global segment, pendingUnpause

    if busy
        return

    if finished {
        ToolTip "Mapping already finished. Press " . KeyLabel("clear") . " to clear it."
        return
    }

    recording := !recording

    if recording {
        mappingStarted := true

        if (points.Length > 0) {
            segment += 1
            pendingUnpause := true
        }

        rateCount := 0
        rateStart := A_TickCount

        SetTimer(ShowStartScreen, 0)
        SetTimer(ReadCoordinates, 1)
        SetTimer(UpdateStatus, 250)
        SetTimer(AutoSave, autosaveInterval)
    } else {
        SetTimer(ReadCoordinates, 0)
        SetTimer(UpdateStatus, 0)
        SetTimer(AutoSave, 0)

        if pendingUnpause {
            pendingUnpause := false
            segment -= 1
        } else if (lastX != "" && lastZ != "") {
            markers.Push({x: lastX, z: lastZ, name: "Paused", kind: 1})
            dirty := true
        }

        AutoSave()

        saveLabel := (lastSave = "") ? "none yet" : lastSave

        ToolTip "PAUSED`nPoints collected: " points.Length "`nLast autosave: " saveLabel
    }
}

; OCRs the HUD and stores the current x/z point.
ReadCoordinates() {
    global recording, reading
    global points, rateCount, failedReads
    global lastX, lastZ, dirty
    global markers, segment, pendingUnpause
    global hudX, hudY, hudWidth, hudHeight

    if !recording || reading
        return

    reading := true

    try {
        rawText := OCR.FromRect(hudX, hudY, hudWidth, hudHeight, {scale: 2, grayscale: true}).Text

        if !RegExMatch(rawText, "(-?\d+)\s*,\s*-?\d+\s*,\s*(-?\d+)", &match) {
            failedReads += 1
            return
        }

        x := Integer(match[1])
        z := Integer(match[2])

        lastX := x
        lastZ := z

        if pendingUnpause {
            markers.Push({x: x, z: z, name: "Unpaused", kind: 2})
            pendingUnpause := false
        }

        count := points.Length

        if (count >= 2) {
            prev := points[count]
            before := points[count - 1]

            if (prev.s = segment && before.s = segment && prev.x = x && prev.z = z && before.x = x && before.z = z)
                points.Pop()
        }

        points.Push({x: x, z: z, s: segment})
        rateCount += 1
        dirty := true

    } catch as err {
        failedReads += 1
    } finally {
        reading := false
    }
}

; Reads the current position and saves it as a named pin.
AddPin() {
    global reading, lastX, lastZ
    global markers, finished
    global hudX, hudY, hudWidth, hudHeight
    global dirty, busy

    if busy
        return

    if finished {
        ToolTip "Mapping already finished."
        return
    }

    if reading {
        x := lastX
        z := lastZ
    } else {
        reading := true

        try {
            rawText := OCR.FromRect(hudX, hudY, hudWidth, hudHeight, {scale: 2, grayscale: true}).Text

            if !RegExMatch(rawText, "(-?\d+)\s*,\s*-?\d+\s*,\s*(-?\d+)", &match) {
                ToolTip "Could not recognize coordinates."
                return
            }

            x := Integer(match[1])
            z := Integer(match[2])

            lastX := x
            lastZ := z

        } catch as err {
            ToolTip "OCR ERROR: " err.Message
            return
        } finally {
            reading := false
        }
    }

    if (x = "" || z = "") {
        ToolTip "No coordinates available."
        return
    }

    Suspend true

    result := InputBox(
        "Enter a name for this location:`nX: " x " | Z: " z,
        "Add Map Pin"
    )

    Suspend false

    if (result.Result != "OK")
        return

    pinName := Trim(result.Value)

    if (pinName = "") {
        ToolTip "Pin name cannot be empty."
        return
    }

    markers.Push({x: x, z: z, name: pinName, kind: 0})

    dirty := true
    AutoSave()

    ToolTip "Pin added: " pinName
        . "`nX: " x " | Z: " z
        . "`nTotal pins: " markers.Length
}

; Escapes a string for safe embedding in JS/JSON.
EscapeJSString(value) {
    value := StrReplace(value, "\", "\\")
    value := StrReplace(value, Chr(34), "\" . Chr(34))
    value := StrReplace(value, "`r", "\r")
    value := StrReplace(value, "`n", "\n")
    value := StrReplace(value, "`t", "\t")
    value := StrReplace(value, "<", "\u003C")

    return value
}

; Refreshes the tooltip with read rate, counts and controls.
UpdateStatus() {
    global points, rateCount, rateStart, failedReads
    global markers, lastSave, autosaveFailures

    now := A_TickCount
    elapsed := Max(1, now - rateStart)

    rate := Round(rateCount * 1000 / elapsed, 1)

    rateCount := 0
    rateStart := now

    saveLabel := (lastSave = "") ? "waiting" : lastSave

    if autosaveFailures
        saveLabel .= " (" autosaveFailures " failed)"

    ToolTip "MAPPING`n"
        . "Points: " points.Length "`n"
        . "Pins: " markers.Length "`n"
        . "Read rate: " rate " points/sec`n"
        . "Failed reads: " failedReads "`n"
        . "Autosave: " saveLabel "`n"
        . "`n" . KeyLabel("toggle") . ": Pause mapping`n"
        . KeyLabel("finish") . ": Finish and create HTML map`n"
        . KeyLabel("clear") . ": Clear map`n"
        . KeyLabel("pin") . ": Add named pin"
}

; Converts the points list into a JS array literal body.
BuildPointsData(list) {
    data := ""

    for index, point in list {
        if (index > 1)
            data .= ","

        data .= "[" . point.x . "," . point.z . "," . point.s . "]"
    }

    return data
}

; Converts the pins list into a JS array literal body.
BuildMarkersData(list) {
    data := ""

    for index, marker in list {
        if (index > 1)
            data .= ","

        data .= "["
            . marker.x . ","
            . marker.z . ","
            . Chr(34)
            . EscapeJSString(marker.name)
            . Chr(34)
            . "," . marker.kind
            . "]"
    }

    return data
}

; Writes points and pins to a JSON file atomically.
SaveSession(path) {
    global mapFolder, points, markers

    Critical "On"

    try {
        if !DirExist(mapFolder)
            DirCreate(mapFolder)

        json := '{`n'
        json .= '  "format": "FathomMapper session",`n'
        json .= '  "version": 2,`n'
        json .= '  "saved": "' . FormatTime(, "yyyy-MM-dd HH:mm:ss") . '",`n'
        json .= '  "pointFormat": "[x, z, segment]",`n'
        json .= '  "pinFormat": "[x, z, name, kind]",`n'
        json .= '  "points": [' . BuildPointsData(points) . '],`n'
        json .= '  "pins": [' . BuildMarkersData(markers) . ']`n'
        json .= '}`n'

        tempPath := path . ".tmp"

        if FileExist(tempPath)
            FileDelete tempPath

        file := FileOpen(tempPath, "w", "UTF-8-RAW")

        if !IsObject(file)
            throw Error("Could not create data file:`n" tempPath)

        try {
            file.Write(json)
        } finally {
            file.Close()
        }

        FileMove(tempPath, path, 1)
    } finally {
        Critical "Off"
    }
}

; Parses a session JSON file into points and pins.
LoadSession(path, &pts, &pins) {
    pts := []
    pins := []

    try {
        text := FileRead(path, "UTF-8")
    } catch {
        return false
    }

    pointsKey := InStr(text, '"points"')

    if !pointsKey
        return false

    pinsKey := InStr(text, '"pins"', true, pointsKey + 1)

    if !pinsKey
        return false

    pointsText := SubStr(text, pointsKey, pinsKey - pointsKey)
    pinsText := SubStr(text, pinsKey)

    pos := 1

    while RegExMatch(pointsText, "\[\s*(-?\d+)\s*,\s*(-?\d+)\s*(?:,\s*(\d+)\s*)?\]", &m, pos) {
        pts.Push({x: Integer(m[1]), z: Integer(m[2]), s: (m[3] = "") ? 0 : Integer(m[3])})
        pos := m.Pos + m.Len
    }

    pos := 1

    while RegExMatch(pinsText, '\[\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*(?:,\s*(\d+)\s*)?\]', &m, pos) {
        pins.Push({x: Integer(m[1]), z: Integer(m[2]), name: UnescapeJSString(m[3]), kind: (m[4] = "") ? 0 : Integer(m[4])})
        pos := m.Pos + m.Len
    }

    return true
}

; Reverses EscapeJSString.
UnescapeJSString(value) {
    result := ""
    pos := 1
    length := StrLen(value)

    while (pos <= length) {
        ch := SubStr(value, pos, 1)

        if (ch = "\" && pos < length) {
            next := SubStr(value, pos + 1, 1)

            if (next = "u" && RegExMatch(SubStr(value, pos + 2, 4), "^[0-9A-Fa-f]{4}$")) {
                result .= Chr(Integer("0x" . SubStr(value, pos + 2, 4)))
                pos += 6
                continue
            }

            if (next = "n")
                result .= "`n"
            else if (next = "r")
                result .= "`r"
            else if (next = "t")
                result .= "`t"
            else
                result .= next

            pos += 2
        } else {
            result .= ch
            pos += 1
        }
    }

    return result
}

; Saves the session to the autosave file when changed.
AutoSave() {
    global dirty, autosavePath, lastSave, autosaveFailures

    if !dirty
        return

    dirty := false

    try {
        SaveSession(autosavePath)
        lastSave := FormatTime(, "HH:mm:ss")
    } catch {
        dirty := true
        autosaveFailures += 1
    }
}

; Offers to resume an unsaved session found at startup.
CheckForAutosave() {
    global autosavePath, points, markers, dirty
    global lastX, lastZ, busy, segment

    if !FileExist(autosavePath)
        return

    busy := true

    try {
        loadedPoints := []
        loadedMarkers := []

        if !LoadSession(autosavePath, &loadedPoints, &loadedMarkers) {
            keptAs := MoveAsideAutosave("UnreadableAutosave")
            MsgBox("The previous autosave could not be read, so it was kept as:`n`n" keptAs, "FathomMapper", "Icon!")
            return
        }

        if (loadedPoints.Length = 0 && loadedMarkers.Length = 0) {
            FileDelete autosavePath
            return
        }

        answer := MsgBox(
            "An unsaved mapping session was found.`n`n"
            . "Points: " loadedPoints.Length "`n"
            . "Pins: " loadedMarkers.Length "`n"
            . "Last saved: " FormatTime(FileGetTime(autosavePath), "yyyy-MM-dd HH:mm:ss") "`n`n"
            . "Resume it?`n`n"
            . "Yes: continue this session`n"
            . "No: keep the file aside and start a new map",
            "FathomMapper",
            "YesNo Icon?"
        )

        if (answer = "Yes") {
            points := loadedPoints
            markers := loadedMarkers

            if (points.Length > 0) {
                lastX := points[points.Length].x
                lastZ := points[points.Length].z
                segment := points[points.Length].s
            }

            dirty := false

            ToolTip "Session recovered`n"
                . "Points: " points.Length "`n"
                . "Pins: " markers.Length "`n`n"
                . "Press " . KeyLabel("toggle") . " to continue mapping`n"
                . "Press " . KeyLabel("finish") . " to finish"
        } else {
            MoveAsideAutosave("UnsavedSession")
        }
    } finally {
        busy := false
    }
}

; Renames the autosave file so it is kept but not reloaded.
MoveAsideAutosave(prefix) {
    global autosavePath

    target := GetUniqueFilePath(prefix . "_" . FormatTime(, "yyyy-MM-dd_HH-mm-ss"), ".json")
    FileMove(autosavePath, target)

    return target
}

; Returns a file path that does not collide with an existing one.
GetUniqueFilePath(baseName, extension, folder := "") {
    global mapFolder

    if (folder = "")
        folder := mapFolder

    path := folder . "\" . baseName . extension
    counter := 2

    while FileExist(path) {
        path := folder . "\" . baseName . "_" . counter . extension
        counter += 1
    }

    return path
}

; Returns the JSON data path matching an HTML map path.
DataPathFor(htmlPath) {
    return SubStr(htmlPath, 1, -5) . ".json"
}

; Builds a unique timestamped HTML map path.
GetNewMapPath() {
    global mapFolder

    if !DirExist(mapFolder)
        DirCreate(mapFolder)

    stamp := FormatTime(, "yyyy-MM-dd_HH-mm-ss")
    baseName := "CoordinateMap_" . stamp

    path := mapFolder . "\" . baseName . ".html"
    counter := 2

    while FileExist(path) || FileExist(DataPathFor(path)) {
        path := mapFolder . "\" . baseName . "_" . counter . ".html"
        counter += 1
    }

    return path
}

; True once recording began or any data exists.
HasMappingStarted() {
    global mappingStarted, points, markers

    return mappingStarted || points.Length > 0 || markers.Length > 0
}

; Returns the start screen instructions.
StartScreenText() {
    return "Press " . KeyLabel("start") . " to start mapping`n"
        . "Press " . KeyLabel("rebuild") . " to turn a saved data file into a map`n"
        . "Press " . KeyLabel("exit") . " to close the program`n"
        . "Press " . KeyLabel("menu") . " to change keybinds"
}

; Closes the program unless a dialog is busy.
ExitProgram() {
    global busy

    if busy
        return

    ExitApp
}

; Shows the start screen and keeps it refreshed.
BeginStartScreen() {
    ShowStartScreen()
    SetTimer(ShowStartScreen, 50)
}

; Displays the start screen tooltip.
ShowStartScreen() {
    global busy, startNote

    if HasMappingStarted() {
        SetTimer(ShowStartScreen, 0)
        return
    }

    if busy
        return

    if WinExist("Add Map Pin ahk_pid " . ProcessExist()) {
        ToolTip()
        return
    }

    text := StartScreenText()

    if (startNote != "")
        text := startNote . "`n`n" . text

    ToolTip(text)
}

; Sets a temporary note shown on the start screen.
SetStartNote(text) {
    global startNote

    startNote := text
    SetTimer(ClearStartNote, -8000)
}

; Removes the start screen note.
ClearStartNote() {
    global startNote

    startNote := ""
}

; Converts a hotkey string into readable text, e.g. ^F1 becomes Ctrl+F1.
HotkeyText(key) {
    names := Map("^", "Ctrl+", "!", "Alt+", "+", "Shift+", "#", "Win+")
    result := ""

    while (key != "" && names.Has(SubStr(key, 1, 1))) {
        result .= names[SubStr(key, 1, 1)]
        key := SubStr(key, 2)
    }

    return result . key
}

; Returns the readable key currently bound to an action.
KeyLabel(action) {
    global keybinds

    return HotkeyText(keybinds[action])
}

; Loads saved keybinds from the INI file, using defaults where missing.
LoadKeybinds() {
    global keybinds, keybindActions, keybindDefaults, keybindPath

    keybinds := Map()

    for action in keybindActions {
        key := IniRead(keybindPath, "Keybinds", action, keybindDefaults[action])
        keybinds[action] := (key = "") ? keybindDefaults[action] : key
    }
}

; Writes the current keybinds to the INI file.
SaveKeybinds() {
    global keybinds, keybindActions, keybindPath, settingsFolder

    if !DirExist(settingsFolder)
        DirCreate(settingsFolder)

    for action in keybindActions
        IniWrite(keybinds[action], keybindPath, "Keybinds", action)
}

; True while the start screen is showing.
InStartScreen(*) {
    return !HasMappingStarted()
}

; True once a mapping session has begun.
InSession(*) {
    return HasMappingStarted()
}

; Registers each hotkey for its own screen, replacing any previous ones.
ApplyKeybinds() {
    global keybinds, keybindActions, keybindDefaults, keybindCallbacks, keybindGroups, boundKeys

    for bound in boundKeys {
        HotIf(bound.context)

        try Hotkey(bound.name, "Off")
    }

    boundKeys := []

    for action in keybindActions {
        context := (keybindGroups[action] = "start") ? InStartScreen : InSession
        key := keybinds[action]

        HotIf(context)

        try {
            Hotkey(key, keybindCallbacks[action], "On")
        } catch {
            key := keybindDefaults[action]
            keybinds[action] := key
            Hotkey(key, keybindCallbacks[action], "On")
        }

        boundKeys.Push({context: context, name: key})
    }

    HotIf()
}

; Opens the keybind editor from the start screen.
OpenKeybindMenu() {
    global busy, keybinds, keybindActions, keybindLabels, keybindGui, keybindControls

    if busy || HasMappingStarted()
        return

    busy := true

    ToolTip()
    Suspend true

    keybindGui := Gui("+AlwaysOnTop", "FathomMapper Keybinds")
    keybindGui.OnEvent("Close", CloseKeybindMenu)
    keybindGui.Add("Text", "w370", "Click a box, then press the key or key combination to use. A key can repeat between the start screen and mapping, but not within one.")

    keybindControls := Map()

    for action in keybindActions {
        keybindGui.Add("Text", "xm w260 h21 +0x200", keybindLabels[action])
        keybindControls[action] := keybindGui.Add("Hotkey", "x+10 yp w130 h21", keybinds[action])
    }

    keybindGui.Add("Button", "xm w90", "Save").OnEvent("Click", SaveKeybindMenu)
    keybindGui.Add("Button", "x+8 w120", "Reset to defaults").OnEvent("Click", ResetKeybindMenu)
    keybindGui.Add("Button", "x+8 w90", "Cancel").OnEvent("Click", CloseKeybindMenu)

    keybindGui.Show("AutoSize Center")
}

; Validates the chosen keys, then saves and applies them.
SaveKeybindMenu(*) {
    global keybinds, keybindActions, keybindGroups, keybindControls, keybindPath, keybindGui

    keybindGui.Opt("+OwnDialogs")

    newKeys := Map()
    used := Map()
    used.CaseSense := false

    for action in keybindActions {
        key := keybindControls[action].Value

        if (key = "") {
            MsgBox("Every action needs a key.", "FathomMapper", "Icon!")
            return
        }

        group := keybindGroups[action]

        if used.Has(group . ":" . key) {
            where := (group = "start") ? "the start screen" : "mapping"
            MsgBox("The key " . HotkeyText(key) . " is assigned to more than one action on " . where . ".", "FathomMapper", "Icon!")
            return
        }

        used[group . ":" . key] := true
        newKeys[action] := key
    }

    keybinds := newKeys

    try {
        SaveKeybinds()
    } catch {
        MsgBox("The keybinds could not be saved to:`n`n" keybindPath "`n`nThey will only last until the program closes.", "FathomMapper", "Icon!")
    }

    ApplyKeybinds()
    CloseKeybindMenu()
    SetStartNote("Keybinds saved.")
}

; Puts the default keys back into the editor boxes.
ResetKeybindMenu(*) {
    global keybindActions, keybindControls, keybindDefaults

    for action in keybindActions
        keybindControls[action].Value := keybindDefaults[action]
}

; Closes the keybind editor and re-enables hotkeys.
CloseKeybindMenu(*) {
    global busy, keybindGui

    keybindGui.Destroy()
    keybindGui := ""

    Suspend false
    busy := false
}

; Turns a chosen JSON data file into a new HTML map.
RebuildMap() {
    global finished, busy, mapFolder

    if busy
        return

    if finished
        return

    if HasMappingStarted()
        return

    busy := true

    ClearStartNote()

    try {
        startFolder := DirExist(mapFolder) ? mapFolder : A_ScriptDir

        ToolTip()

        selected := FileSelect(1, startFolder, "Choose a data file to turn into a map", "Map data (*.json)")

        if (selected = "")
            return

        loadedPoints := []
        loadedMarkers := []

        if !LoadSession(selected, &loadedPoints, &loadedMarkers) {
            MsgBox("That file could not be read as a FathomMapper data file.`n`n" selected, "FathomMapper", "Icon!")
            return
        }

        if (loadedPoints.Length = 0 && loadedMarkers.Length = 0) {
            MsgBox("That data file does not contain any points or pins.", "FathomMapper", "Icon!")
            return
        }

        SplitPath(selected, , &folder, , &baseName)
        outPath := GetUniqueFilePath(baseName . "_rebuilt", ".html", folder)

        ToolTip "Creating HTML map..."

        WriteMapHtml(outPath, BuildPointsData(loadedPoints), BuildMarkersData(loadedMarkers))

        SplitPath(outPath, &outName)
        SetStartNote("Map rebuilt:`n" . outName)

        Run('"' outPath '"')
    } catch as err {
        SetStartNote("REBUILD ERROR: " . err.Message)
    } finally {
        busy := false
    }
}

; Stops recording, creates the HTML map and exits.
FinishMapping() {
    global recording, finished, mapPath
    global autosavePath, busy
    global points, markers

    if busy
        return

    recording := false

    SetTimer(ReadCoordinates, 0)
    SetTimer(UpdateStatus, 0)
    SetTimer(AutoSave, 0)

    if (points.Length = 0 && markers.Length = 0)
        ExitApp

    ToolTip "Creating HTML map..."

    try {
        CreateMap()
        finished := true

        try {
            if FileExist(autosavePath)
                FileDelete autosavePath
        } catch {
        }

        Run('"' mapPath '"')
        ExitApp

    } catch as err {
        ToolTip "MAP ERROR: " err.Message
    }
}

; Clears all session state and the autosave file.
ResetMapping() {
    global recording, finished, points, markers
    global rateCount, failedReads, rateStart
    global lastX, lastZ
    global dirty, lastSave, autosaveFailures, autosavePath, busy, mappingStarted
    global segment, pendingUnpause

    if busy
        return

    recording := false
    finished := false
    mappingStarted := false
    segment := 0
    pendingUnpause := false
    points := []
    markers := []

    dirty := false
    lastSave := ""
    autosaveFailures := 0

    lastX := ""
    lastZ := ""

    rateCount := 0
    failedReads := 0
    rateStart := A_TickCount

    SetTimer(ReadCoordinates, 0)
    SetTimer(UpdateStatus, 0)
    SetTimer(AutoSave, 0)

    try {
        if FileExist(autosavePath)
            FileDelete autosavePath
    } catch {
    }

    SetStartNote("Map cleared.")
    BeginStartScreen()
}

; Saves the data file and writes the HTML map.
CreateMap() {
    global points, markers, mapPath

    mapPath := GetNewMapPath()

    SaveSession(DataPathFor(mapPath))

    WriteMapHtml(mapPath, BuildPointsData(points), BuildMarkersData(markers))
}

; Writes the interactive HTML map with the data inserted.
WriteMapHtml(path, pointsData, markersData) {
    html := "
(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Coordinate Map</title>
<style>
* {
    box-sizing: border-box;
}
html, body {
    width: 100%;
    height: 100%;
    margin: 0;
    overflow: hidden;
    font-family: Arial, sans-serif;
    background: #f4f5f7;
}
#buttons {
    height: 58px;
    padding: 10px 14px;
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 12px;
    background: #fff;
    border-bottom: 1px solid #ccc;
    position: relative;
    z-index: 2;
}
#buttons label {
    font-size: 14px;
    font-weight: bold;
}
#maxJump {
    width: 95px;
    padding: 6px;
    font-size: 14px;
}
button {
    padding: 7px 12px;
    border: 1px solid #bbb;
    border-radius: 4px;
    background: #f8f8f8;
    cursor: pointer;
    font-size: 14px;
}
button:hover {
    background: #e8e8e8;
}
#stats {
    font-size: 13px;
    color: #444;
}
#coords {
    margin-left: auto;
    min-width: 150px;
    text-align: right;
    font-size: 13px;
    color: #444;
    font-variant-numeric: tabular-nums;
}
#mapWrap {
    position: absolute;
    inset: 58px 0 0 0;
}
#map {
    display: block;
    width: 100%;
    height: 100%;
    cursor: grab;
    touch-action: none;
}
#map.dragging {
    cursor: grabbing;
}
</style>
</head>
<body>
<div id="buttons">
    <label for="maxJump">Max jump:</label>
    <input id="maxJump" type="number" min="0" step="1" value="22">
    <span id="stats"></span>
    <button id="zoomIn">+</button>
    <button id="zoomOut">-</button>
    <button id="fit">Fit map</button>
    <span id="coords"></span>
</div>
<div id="mapWrap">
    <canvas id="map"></canvas>
</div>
<script>
const rawPoints = [__POINTS__];
const rawMarkers = [__MARKERS__];

const canvas = document.getElementById("map");
const ctx = canvas.getContext("2d");
const maxJumpInput = document.getElementById("maxJump");
const stats = document.getElementById("stats");
const coords = document.getElementById("coords");

let filteredPoints = [];

// Style for named pins; each pause/resume pair gets its own blue/purple shade.
const markerStyles = {
    0: { fill: "#f59e0b", stroke: "#7c2d12", text: "#92400e" }
};

// Numbers each pause/resume pair; pairOf holds a marker's pair or -1.
const pairOf = rawMarkers.map(function() { return -1; });
let pairCount = 0;
let pairOpen = false;

for (let i = 0; i < rawMarkers.length; i++) {
    const kind = rawMarkers[i][3];

    if (kind === 1) {
        pairOf[i] = pairCount;
        pairCount += 1;
        pairOpen = true;
    } else if (kind === 2) {
        if (pairOpen) {
            pairOf[i] = pairCount - 1;
            pairOpen = false;
        } else {
            pairOf[i] = pairCount;
            pairCount += 1;
        }
    }
}

// Returns the style for a marker by index.
function markerStyle(index) {
    const pair = pairOf[index];

    if (pair < 0)
        return markerStyles[0];

    const hue = 240 + ((pair * 0.618034) % 1) * 50;
    const light = 40 + ((pair * 0.381966) % 1) * 22;

    return {
        fill: "hsl(" + hue + ", 75%, " + light + "%)",
        stroke: "hsl(" + hue + ", 75%, 22%)",
        text: "hsl(" + hue + ", 75%, 30%)"
    };
}

// Hides markers of other pairs while a pair is selected.
function markerVisible(index) {
    const pair = pairOf[index];

    return pair < 0 || selectedPair < 0 || pair === selectedPair;
}

// Current zoom and pan state.
let view = {
    scale: 1,
    fitScale: 1,
    offsetX: 0,
    offsetY: 0
};

let selectedPair = -1;
let mouse = { x: 0, y: 0, inside: false };

let dragging = false;
let lastMouseX = 0;
let lastMouseY = 0;
let downX = 0;
let downY = 0;

// Drops points that jump farther than the max jump value.
function filterPoints() {
    const value = Number(maxJumpInput.value);
    const maxJump = Number.isFinite(value) ? Math.max(0, value) : 0;

    if (rawPoints.length === 0)
        return [];

    const result = [rawPoints[0]];

    for (let i = 1; i < rawPoints.length; i++) {
        const point = rawPoints[i];
        const last = result[result.length - 1];

        const dx = point[0] - last[0];
        const dz = point[1] - last[1];

        const distance = Math.hypot(dx, dz);

        const newPath = point[2] !== last[2];

        if (maxJump === 0 || newPath || distance <= maxJump) {
            result.push(point);
        }
    }

    return result;
}

// Refilters points, updates stats and refits the view.
function updateMap() {
    filteredPoints = filterPoints();

    const removed = rawPoints.length - filteredPoints.length;

    stats.textContent =
        filteredPoints.length.toLocaleString() + " kept / " +
        removed.toLocaleString() + " removed / " +
        rawPoints.length.toLocaleString() + " total / " +
        rawMarkers.length + " pins";

    fitMap();
}

// Matches the canvas resolution to its display size.
function resizeCanvas() {
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;

    canvas.width = Math.round(rect.width * dpr);
    canvas.height = Math.round(rect.height * dpr);

    fitMap();
}

// Scales and centers the view to fit all points and pins.
function fitMap() {
    const allPoints = filteredPoints.concat(
        rawMarkers.map(marker => [marker[0], marker[1]])
    `);

    if (allPoints.length === 0)
        return;

    const rect = canvas.getBoundingClientRect();
    const width = rect.width;
    const height = rect.height;
    const padding = 50;

    let minX = allPoints[0][0];
    let maxX = allPoints[0][0];
    let minZ = allPoints[0][1];
    let maxZ = allPoints[0][1];

    for (const point of allPoints) {
        minX = Math.min(minX, point[0]);
        maxX = Math.max(maxX, point[0]);
        minZ = Math.min(minZ, point[1]);
        maxZ = Math.max(maxZ, point[1]);
    }

    let rangeX = maxX - minX;
    let rangeZ = maxZ - minZ;

    if (rangeX === 0) rangeX = 1;
    if (rangeZ === 0) rangeZ = 1;

    const scale = Math.min(
        (width - padding * 2) / rangeX,
        (height - padding * 2) / rangeZ
    `);

    view.scale = scale;
    view.fitScale = scale;

    view.offsetX = (width - rangeX * scale) / 2 - minX * scale;
    view.offsetY = (height + rangeZ * scale) / 2 + minZ * scale;

    drawMap();
}

// Draws the axes, path, pins and labels.
function drawMap() {
    updateCoords();

    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, rect.width, rect.height);

    if (filteredPoints.length === 0 && rawMarkers.length === 0)
        return;

    ctx.setTransform(
        dpr * view.scale,
        0,
        0,
        -dpr * view.scale,
        dpr * view.offsetX,
        dpr * view.offsetY
    `);

    const worldLeft = -view.offsetX / view.scale;
    const worldRight = (rect.width - view.offsetX) / view.scale;
    const worldTop = view.offsetY / view.scale;
    const worldBottom = (view.offsetY - rect.height) / view.scale;

    ctx.beginPath();
    ctx.moveTo(worldLeft, 0);
    ctx.lineTo(worldRight, 0);
    ctx.moveTo(0, worldBottom);
    ctx.lineTo(0, worldTop);
    ctx.strokeStyle = "#9ca3af";
    ctx.lineWidth = 1.5 / view.scale;
    ctx.stroke();

    if (filteredPoints.length > 0) {
        ctx.beginPath();

        for (let i = 0; i < filteredPoints.length; i++) {
            const point = filteredPoints[i];

            if (i === 0 || point[2] !== filteredPoints[i - 1][2])
                ctx.moveTo(point[0], point[1]);
            else
                ctx.lineTo(point[0], point[1]);
        }

        ctx.strokeStyle = "#2563eb";
        ctx.lineWidth = 2.2 / view.scale;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        ctx.stroke();

        const first = filteredPoints[0];
        const last = filteredPoints[filteredPoints.length - 1];

        ctx.beginPath();
        ctx.arc(first[0], first[1], 4 / view.scale, 0, Math.PI * 2);
        ctx.fillStyle = "#16a34a";
        ctx.fill();

        ctx.beginPath();
        ctx.arc(last[0], last[1], 4 / view.scale, 0, Math.PI * 2);
        ctx.fillStyle = "#dc2626";
        ctx.fill();
    }

    for (let i = 0; i < rawMarkers.length; i++) {
        if (!markerVisible(i))
            continue;

        const marker = rawMarkers[i];
        const style = markerStyle(i);
        const radius = 6 / view.scale;

        ctx.beginPath();

        if (marker[3] === 1)
            ctx.rect(marker[0] - radius, marker[1] - radius, radius * 2, radius * 2);
        else
            ctx.arc(marker[0], marker[1], radius, 0, Math.PI * 2);

        ctx.fillStyle = style.fill;
        ctx.fill();

        ctx.lineWidth = 1.5 / view.scale;
        ctx.strokeStyle = style.stroke;
        ctx.stroke();
    }

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = "13px Arial";

    if (filteredPoints.length > 0) {
        const first = filteredPoints[0];
        const last = filteredPoints[filteredPoints.length - 1];

        ctx.fillStyle = "#16a34a";
        ctx.fillText(
            "START",
            first[0] * view.scale + view.offsetX + 8,
            view.offsetY - first[1] * view.scale - 8
        `);

        ctx.fillStyle = "#dc2626";
        ctx.fillText(
            "END",
            last[0] * view.scale + view.offsetX + 8,
            view.offsetY - last[1] * view.scale - 8
        `);
    }

    for (let i = 0; i < rawMarkers.length; i++) {
        if (!markerVisible(i))
            continue;

        const marker = rawMarkers[i];
        const screenX = marker[0] * view.scale + view.offsetX;
        const screenY = view.offsetY - marker[1] * view.scale;

        ctx.fillStyle = markerStyle(i).text;
        ctx.fillText(marker[2], screenX + 10, screenY - 9);
    }
}

// Returns the pair of the nearest visible pause/resume marker to a screen position, or -1.
function pickPair(x, y) {
    let best = -1;
    let bestDistance = 12;

    for (let i = 0; i < rawMarkers.length; i++) {
        if (pairOf[i] < 0 || !markerVisible(i))
            continue;

        const screenX = rawMarkers[i][0] * view.scale + view.offsetX;
        const screenY = view.offsetY - rawMarkers[i][1] * view.scale;
        const distance = Math.hypot(screenX - x, screenY - y);

        if (distance < bestDistance) {
            best = pairOf[i];
            bestDistance = distance;
        }
    }

    return best;
}

// Shows the map x/z under the mouse.
function updateCoords() {
    if (!mouse.inside) {
        coords.textContent = "";
        return;
    }

    const x = Math.round((mouse.x - view.offsetX) / view.scale);
    const z = Math.round((view.offsetY - mouse.y) / view.scale);

    coords.textContent = "X: " + x + "   Z: " + z;
}

// Zooms around a screen position.
function zoomAt(x, y, factor) {
    const worldX = (x - view.offsetX) / view.scale;
    const worldZ = (view.offsetY - y) / view.scale;

    const newScale = Math.max(
        view.fitScale * 0.00001,
        Math.min(view.fitScale * 100000, view.scale * factor)
    `);

    view.scale = newScale;
    view.offsetX = x - worldX * newScale;
    view.offsetY = y + worldZ * newScale;

    drawMap();
}

// Zooms with the mouse wheel.
canvas.addEventListener("wheel", function(event) {
    event.preventDefault();

    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;

    zoomAt(x, y, event.deltaY < 0 ? 1.2 : 1 / 1.2);
}, { passive: false });

// Starts a drag-pan.
canvas.addEventListener("pointerdown", function(event) {
    dragging = true;

    lastMouseX = event.clientX;
    lastMouseY = event.clientY;
    downX = event.clientX;
    downY = event.clientY;

    canvas.style.cursor = "";
    canvas.classList.add("dragging");
    canvas.setPointerCapture(event.pointerId);
});

// Tracks the cursor for the coordinate readout and pans while dragging.
canvas.addEventListener("pointermove", function(event) {
    const rect = canvas.getBoundingClientRect();

    mouse.x = event.clientX - rect.left;
    mouse.y = event.clientY - rect.top;
    mouse.inside = true;

    if (!dragging) {
        canvas.style.cursor = pickPair(mouse.x, mouse.y) >= 0 ? "pointer" : "";
        updateCoords();
        return;
    }

    const dx = event.clientX - lastMouseX;
    const dy = event.clientY - lastMouseY;

    view.offsetX += dx;
    view.offsetY += dy;

    lastMouseX = event.clientX;
    lastMouseY = event.clientY;

    drawMap();
});

// Ends a drag-pan.
function stopDragging() {
    dragging = false;
    canvas.classList.remove("dragging");
}

// Ends a drag-pan; a click without movement selects a pair, or deselects when it hits none.
canvas.addEventListener("pointerup", function(event) {
    const moved = Math.hypot(event.clientX - downX, event.clientY - downY);

    stopDragging();

    if (moved > 4)
        return;

    const rect = canvas.getBoundingClientRect();

    selectedPair = pickPair(event.clientX - rect.left, event.clientY - rect.top);
    drawMap();
});

canvas.addEventListener("pointercancel", stopDragging);

// Clears the coordinate readout when the cursor leaves the map.
canvas.addEventListener("pointerleave", function() {
    mouse.inside = false;
    updateCoords();
});

// Zooms in on double-click.
canvas.addEventListener("dblclick", function(event) {
    const rect = canvas.getBoundingClientRect();

    zoomAt(
        event.clientX - rect.left,
        event.clientY - rect.top,
        2
    `);
});

// Zoom in button.
document.getElementById("zoomIn").addEventListener("click", function() {
    zoomAt(canvas.clientWidth / 2, canvas.clientHeight / 2, 1.5);
});

// Zoom out button.
document.getElementById("zoomOut").addEventListener("click", function() {
    zoomAt(canvas.clientWidth / 2, canvas.clientHeight / 2, 1 / 1.5);
});

document.getElementById("fit").addEventListener("click", fitMap);

maxJumpInput.addEventListener("input", updateMap);

window.addEventListener("resize", resizeCanvas);

// Keyboard zoom (+/-) and fit (0).
window.addEventListener("keydown", function(event) {
    if (document.activeElement === maxJumpInput)
        return;

    if (event.key === "+" || event.key === "=")
        zoomAt(canvas.clientWidth / 2, canvas.clientHeight / 2, 1.5);

    if (event.key === "-")
        zoomAt(canvas.clientWidth / 2, canvas.clientHeight / 2, 1 / 1.5);

    if (event.key === "0")
        fitMap();
});

resizeCanvas();
updateMap();
</script>
</body>
</html>
)"

    html := StrReplace(html, "__POINTS__", pointsData)
    html := StrReplace(html, "__MARKERS__", markersData)

    file := FileOpen(path, "w", "UTF-8-RAW")

    if !IsObject(file)
        throw Error("Could not create HTML file:`n" path)

    try {
        file.Write(html)
    } finally {
        file.Close()
    }
}
