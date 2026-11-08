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

OnExit(Cleanup)

F1::ToggleRecording()
F2::FinishMapping()
F3::ResetMapping()
F4::AddPin()

Cleanup(*) {
    SetTimer(ReadCoordinates, 0)
    SetTimer(UpdateStatus, 0)
    DllCall("Winmm\timeEndPeriod", "UInt", 1)
    ToolTip()
}

ToggleRecording() {
    global recording, finished, points
    global rateCount, rateStart

    if finished {
        ToolTip "Mapping already finished. Press F3 to clear it."
        return
    }

    recording := !recording

    if recording {
        rateCount := 0
        rateStart := A_TickCount

        SetTimer(ReadCoordinates, 1)
        SetTimer(UpdateStatus, 250)
    } else {
        SetTimer(ReadCoordinates, 0)
        SetTimer(UpdateStatus, 0)

        ToolTip "PAUSED`nPoints collected: " points.Length
    }
}

ReadCoordinates() {
    global recording, reading
    global points, rateCount, failedReads
    global lastX, lastZ
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

        points.Push({x: x, z: z})
        rateCount += 1

    } catch as err {
        failedReads += 1
    } finally {
        reading := false
    }
}

AddPin() {
    global reading, lastX, lastZ
    global markers, finished
    global hudX, hudY, hudWidth, hudHeight

    if finished {
        ToolTip "Mapping already finished."
        return
    }

    ; grabs the coordinates

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

    result := InputBox(
        "Enter a name for this location:`nX: " x " | Z: " z,
        "Add Map Pin"
    )

    if (result.Result != "OK")
        return

    pinName := Trim(result.Value)

    if (pinName = "") {
        ToolTip "Pin name cannot be empty."
        return
    }

    markers.Push({x: x, z: z, name: pinName})

    ToolTip "Pin added: " pinName
        . "`nX: " x " | Z: " z
        . "`nTotal pins: " markers.Length
}

EscapeJSString(value) {
    value := StrReplace(value, "\", "\\")
    value := StrReplace(value, Chr(34), "\" . Chr(34))
    value := StrReplace(value, "`r", "\r")
    value := StrReplace(value, "`n", "\n")
    value := StrReplace(value, "`t", "\t")
    value := StrReplace(value, "<", "\u003C")

    return value
}

UpdateStatus() {
    global points, rateCount, rateStart, failedReads
    global markers

    now := A_TickCount
    elapsed := Max(1, now - rateStart)

    rate := Round(rateCount * 1000 / elapsed, 1)

    rateCount := 0
    rateStart := now

    ToolTip "MAPPING`n"
        . "Points: " points.Length "`n"
        . "Pins: " markers.Length "`n"
        . "Read rate: " rate " points/sec`n"
        . "Failed reads: " failedReads "`n"
        . "`nF1: Pause mapping`n"
        . "F2: Finish and create HTML map`n"
        . "F3: Clear map`n"
        . "F4: Add named pin"
}

GetNewMapPath() {
    global mapFolder

    if !DirExist(mapFolder)
        DirCreate(mapFolder)

    stamp := FormatTime(, "yyyy-MM-dd_HH-mm-ss")
    baseName := "CoordinateMap_" . stamp

    path := mapFolder . "\" . baseName . ".html"
    counter := 2

    ; add a number to the end if one with the same name already exists
    while FileExist(path) {
        path := mapFolder . "\" . baseName . "_" . counter . ".html"
        counter += 1
    }

    return path
}

FinishMapping() {
    global recording, finished, mapPath

    recording := false

    SetTimer(ReadCoordinates, 0)
    SetTimer(UpdateStatus, 0)

    ToolTip "Creating HTML map..."

    try {
        CreateMap()
        finished := true

        Run('"' mapPath '"')
        ExitApp

    } catch as err {
        ToolTip "MAP ERROR: " err.Message
    }
}

ResetMapping() {
    global recording, finished, points, markers
    global rateCount, failedReads, rateStart
    global lastX, lastZ

    recording := false
    finished := false
    points := []
    markers := []

    lastX := ""
    lastZ := ""

    rateCount := 0
    failedReads := 0
    rateStart := A_TickCount

    SetTimer(ReadCoordinates, 0)
    SetTimer(UpdateStatus, 0)

    ToolTip "Map cleared.`nPress F1 to start mapping."
}

CreateMap() {
    global points, markers, mapPath

    ; converts the points into js arrays

    pointsData := ""

    for index, point in points {
        if (index > 1)
            pointsData .= ","

        pointsData .= "[" . point.x . "," . point.z . "]"
    }

    markersData := ""

    for index, marker in markers {
        if (index > 1)
            markersData .= ","

        markersData .= "["
            . marker.x . ","
            . marker.z . ","
            . Chr(34)
            . EscapeJSString(marker.name)
            . Chr(34)
            . "]"
    }

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

let filteredPoints = [];

let view = {
    scale: 1,
    fitScale: 1,
    offsetX: 0,
    offsetY: 0
};

let dragging = false;
let lastMouseX = 0;
let lastMouseY = 0;

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

        if (maxJump === 0 || distance <= maxJump) {
            result.push(point);
        }
    }

    return result;
}

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

function resizeCanvas() {
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;

    canvas.width = Math.round(rect.width * dpr);
    canvas.height = Math.round(rect.height * dpr);

    fitMap();
}

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

function drawMap() {
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

    // draws the path

    if (filteredPoints.length > 0) {
        ctx.beginPath();

        for (let i = 0; i < filteredPoints.length; i++) {
            const point = filteredPoints[i];

            if (i === 0)
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

    // draws pins

    for (const marker of rawMarkers) {
        ctx.beginPath();
        ctx.arc(marker[0], marker[1], 6 / view.scale, 0, Math.PI * 2);
        ctx.fillStyle = "#f59e0b";
        ctx.fill();

        ctx.lineWidth = 1.5 / view.scale;
        ctx.strokeStyle = "#7c2d12";
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

    for (const marker of rawMarkers) {
        const screenX = marker[0] * view.scale + view.offsetX;
        const screenY = view.offsetY - marker[1] * view.scale;

        ctx.fillStyle = "#92400e";
        ctx.fillText(marker[2], screenX + 10, screenY - 9);
    }
}

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

canvas.addEventListener("wheel", function(event) {
    event.preventDefault();

    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;

    zoomAt(x, y, event.deltaY < 0 ? 1.2 : 1 / 1.2);
}, { passive: false });

canvas.addEventListener("pointerdown", function(event) {
    dragging = true;

    lastMouseX = event.clientX;
    lastMouseY = event.clientY;

    canvas.classList.add("dragging");
    canvas.setPointerCapture(event.pointerId);
});

canvas.addEventListener("pointermove", function(event) {
    if (!dragging)
        return;

    const dx = event.clientX - lastMouseX;
    const dy = event.clientY - lastMouseY;

    view.offsetX += dx;
    view.offsetY += dy;

    lastMouseX = event.clientX;
    lastMouseY = event.clientY;

    drawMap();
});

function stopDragging() {
    dragging = false;
    canvas.classList.remove("dragging");
}

canvas.addEventListener("pointerup", stopDragging);
canvas.addEventListener("pointercancel", stopDragging);

canvas.addEventListener("dblclick", function(event) {
    const rect = canvas.getBoundingClientRect();

    zoomAt(
        event.clientX - rect.left,
        event.clientY - rect.top,
        2
    `);
});

document.getElementById("zoomIn").addEventListener("click", function() {
    zoomAt(canvas.clientWidth / 2, canvas.clientHeight / 2, 1.5);
});

document.getElementById("zoomOut").addEventListener("click", function() {
    zoomAt(canvas.clientWidth / 2, canvas.clientHeight / 2, 1 / 1.5);
});

document.getElementById("fit").addEventListener("click", fitMap);

maxJumpInput.addEventListener("input", updateMap);

window.addEventListener("resize", resizeCanvas);

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

    ; inserts the recorded points

    html := StrReplace(html, "__POINTS__", pointsData)
    html := StrReplace(html, "__MARKERS__", markersData)

    ; creates the FathomMaps folder if needed

    mapPath := GetNewMapPath()

    file := FileOpen(mapPath, "w", "UTF-8-RAW")

    if !IsObject(file)
        throw Error("Could not create HTML file:`n" mapPath)

    try {
        file.Write(html)
    } finally {
        file.Close()
    }
}
