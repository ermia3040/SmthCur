#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode("Mouse", "Screen")

; ===================== Run as Administrator =====================
; If AutoHotkey is installed in Program Files, its UIA (UI Access) version is used.
; Its windows can stay above most Windows layers (Task Manager, Start, taskbar, etc.)
SplitPath(A_AhkPath, , &ahkDir)
uiaExe := ahkDir "\AutoHotkey" (A_PtrSize = 8 ? "64" : "32") "_UIA.exe"
canUIA := !A_IsCompiled && InStr(A_AhkPath, A_ProgramFiles) = 1 && FileExist(uiaExe)
isUIA  := InStr(A_AhkPath, "_UIA.exe") > 0

if ((!A_IsAdmin || (canUIA && !isUIA)) && !RegExMatch(DllCall("GetCommandLine", "Str"), " /restart(?!\S)")) {
    try {
        if A_IsCompiled
            Run('*RunAs "' A_ScriptFullPath '" /restart')
        else
            Run('*RunAs "' (canUIA ? uiaExe : A_AhkPath) '" /restart "' A_ScriptFullPath '"')
    }
    ExitApp()
}

; ===================== Settings =====================
CURSOR_SIZE      := 24            ; cursor size in pixels
HOVER_SCALE      := 1.8           ; scale up on links / clickable items
MOVE_SCALE       := 0.95          ; size while moving
PRESS_SCALE      := 0.85          ; shrink factor while click is held
FILL_COLOR       := 0xFF000000    ; fill color (ARGB)
STROKE_COLOR     := 0xFFFFFFFF    ; outline color (ARGB)
STROKE_WIDTH     := 1.5           ; outline width
ROTATE_MIN_SPEED := 120           ; minimum speed (px/s) before rotation starts

RIPPLE_MS        := 450           ; click ripple animation duration (ms)
TRAIL_N          := 14            ; number of trail points
MAX_USER_SCALE   := 2.0           ; max user scale with Ctrl+Alt+Up
MIN_USER_SCALE   := 0.6           ; min user scale with Ctrl+Alt+Down

; Base spring parameters for rotation and size.
; The motion spring is set in the Settings window.
ROT_K := 600, ROT_C := 30         ; rotation
SCL_K := 500, SCL_C := 35         ; size
HOVER_MAX := 2.5                  ; max hover scale, used to calculate render canvas

; Color themes: [fill, outline] — change with Ctrl+Alt+C
THEMES := [[FILL_COLOR, STROKE_COLOR]
         , [0xFFFFFFFF, 0xFF000000]
         , [0xFF2563EB, 0xFFFFFFFF]
         , [0xFFEF4444, 0xFFFFFFFF]
         , [0xFF10B981, 0xFF064E3B]]

; ---------- Settings editable in the Settings window ----------
; [key, title, min, max, default, display suffix]
SLIDERS := [["smoothMs",     "Smooth time  (0 = follow the mouse instantly)", 0, 400, 150, " ms"]
          , ["boost",        "Speed boost  (stiffer = less lag when the mouse is fast)", 0, 100, 60, " %"]
          , ["maxLag",       "Max lag distance  (0 = unlimited)", 0, 400, 90, " px"]
          , ["bounce",       "Damping  (lower = more bounce)", 30, 150, 75, " %"]
          , ["rotSmooth",    "Rotation speed", 30, 300, 100, " %"]
          , ["hover",        "Size on links / buttons", 100, 250, 180, " %"]
          , ["size",         "Cursor size", 60, 200, 100, " %"]
          , ["pointerSpeed", "Windows pointer speed  (1-20, 10 = default)", 1, 20, 10, ""]]
CFG := Map()
for sd in SLIDERS
    CFG[sd[1]] := sd[5]

; Feature states
RIPPLE_ON := true
TRAIL_ON  := false
userScale := 1.0
themeIdx  := 1
dbg       := false
AUTOSAVE  := true                 ; auto-save settings
bootEnabled := false              ; is "start with Windows" enabled?
NO_ACCEL  := true                 ; disable pointer acceleration while app is running
OVR_SPEED := false                ; override Windows pointer speed while app is running
mouseOrig := ""                   ; original mouse settings, used for restore
setGui := ""                      ; Settings window
uiCtrls := Map()
cbAccel := ""
cbSpeed := ""

SETTINGS_DIR := A_AppData "\SmoothCursor"
SETTINGS_INI := SETTINGS_DIR "\settings.ini"
BOOT_TASK    := "SmoothCursor"    ; Scheduled Task name for start on login

LoadSettings()                    ; load saved settings if they exist
SyncDerived()                     ; compute userScale and HOVER_SCALE from settings

; ===================== Setup =====================
; If the script closed unexpectedly last time, restore system cursors.
DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)
DllCall("winmm\timeBeginPeriod", "UInt", 1)

dpi      := A_ScreenDPI / 96
baseSize := CURSOR_SIZE * dpi
CANVAS   := Ceil(2 * (baseSize * HOVER_MAX * MAX_USER_SCALE * 1.2 + 12 * dpi))
if Mod(CANVAS, 2)
    CANVAS += 1
half := CANVAS // 2

; --- GDI+ ---
DllCall("LoadLibrary", "Str", "gdiplus")
si := Buffer(8 + 2 * A_PtrSize, 0)
NumPut("UInt", 1, si)
DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken := 0, "Ptr", si, "Ptr", 0)

; --- 32-bit bitmap for layered window ---
bi := Buffer(40, 0)
NumPut("UInt", 40, "Int", CANVAS, "Int", -CANVAS, "UShort", 1, "UShort", 32, bi)
hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
hbm := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", bi, "UInt", 0, "Ptr*", &bits := 0, "Ptr", 0, "UInt", 0, "Ptr")
obm := DllCall("SelectObject", "Ptr", hdc, "Ptr", hbm, "Ptr")
DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdc, "Ptr*", &gfx := 0)
DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", gfx, "Int", 4)

; Pens and brushes
DllCall("gdiplus\GdipCreateSolidFill", "UInt", FILL_COLOR, "Ptr*", &brush := 0)       ; arrow fill
DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x30000000, "Ptr*", &shBrush := 0)     ; shadow
DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x80000000, "Ptr*", &trBrush := 0)     ; trail
DllCall("gdiplus\GdipCreatePen1", "UInt", STROKE_COLOR, "Float", 1, "Int", 2, "Ptr*", &pen := 0)     ; outline
DllCall("gdiplus\GdipCreatePen1", "UInt", FILL_COLOR, "Float", 1, "Int", 2, "Ptr*", &ipen := 0)      ; I-beam / spinner lines
DllCall("gdiplus\GdipCreatePen1", "UInt", 0x18000000, "Float", 1, "Int", 2, "Ptr*", &shPen := 0)     ; line shadow
DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFFFFFFFF, "Float", 1, "Int", 2, "Ptr*", &rpen := 0)      ; click ripple
for pp in [pen, ipen, shPen] {
    DllCall("gdiplus\GdipSetPenLineJoin", "Ptr", pp, "Int", 2)
    DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pp, "Int", 2)
    DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pp, "Int", 2)
}
ApplyTheme()

; Arrow shape: tip at (0,0), pointing up
pts := Buffer(32)
NumPut("Float", 0, "Float", 0,
       "Float", 0.40 * baseSize, "Float", baseSize,
       "Float", 0, "Float", 0.78 * baseSize,
       "Float", -0.40 * baseSize, "Float", baseSize, pts)

; --- Transparent click-through window ---
overlay := Gui("-Caption +ToolWindow +AlwaysOnTop +E0x80000 +E0x20 +E0x08000000")
overlay.Show("NA x0 y0 w1 h1")
hwnd := overlay.Hwnd
lastTopCheck := 0
DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)

ptDst := Buffer(8), szBuf := Buffer(8), ptSrc := Buffer(8, 0), blend := Buffer(4, 0)
NumPut("Int", CANVAS, "Int", CANVAS, szBuf)

; --- Simulation state ---
MouseGetPos(&mx0, &my0)
px := mx0, py := my0, vx := 0, vy := 0
ang := 0, ta := 0, va := 0
sc := 1, vs := 0
opac := 0
mvx := 0, mvy := 0
lastMx := mx0, lastMy := my0
lastMode := 0
wasDown := false
ripples := []
trailX := [], trailY := [], trailTick := 0

ci := Buffer(16 + A_PtrSize, 0)
NumPut("UInt", ci.Size, ci)
pt := Buffer(8, 0)
DllCall("QueryPerformanceFrequency", "Int64*", &qpf := 0)
DllCall("QueryPerformanceCounter", "Int64*", &tLast := 0)

; Save original cursor handles before hiding them.
; Some apps like browsers keep the old handle.
hHandOld  := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")
hIBeamOld := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32513, "Ptr")
hWaitOld  := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32514, "Ptr")
hAppOld   := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32650, "Ptr")

; IDs of all Windows system cursors
CURSOR_IDS := [32512, 32513, 32514, 32515, 32516   ; Arrow, IBeam, Wait, Cross, Up
              , 32642, 32643, 32644, 32645, 32646   ; Size NWSE, NESW, WE, NS, All
              , 32648, 32649, 32650, 32651          ; No, Hand, AppStarting, Help
              , 32671, 32672]                       ; Person, Pin

; --- Hide all Windows cursors ---
BlankAllCursors()
OnExit(Cleanup)
OnError(CrashRestore)

; --- Mouse: if the script crashed last time, restore original values, then turn off acceleration ---
RecoverMouseBackup()
BackupMouse()
ApplyMouse()

; Re-apply every 3 seconds in case another app resets cursors, and keep overlay on top.
SetTimer(Maintain, 3000)

; --- Tray menu ---
bootEnabled := IsBootEnabled()
A_IconTip := "Smooth Cursor"
A_TrayMenu.Delete()
A_TrayMenu.Add("Settings...", ShowSettings)
A_TrayMenu.Default := "Settings..."
A_TrayMenu.Add()
A_TrayMenu.Add("Click ripple", ToggleRipple)
A_TrayMenu.Add("Cursor trail", ToggleTrail)
A_TrayMenu.Add("Next color  (Ctrl+Alt+C)", NextTheme)
A_TrayMenu.Add("Bigger  (Ctrl+Alt+Up)", (*) => ChangeSize(0.1))
A_TrayMenu.Add("Smaller  (Ctrl+Alt+Down)", (*) => ChangeSize(-0.1))
A_TrayMenu.Add()
A_TrayMenu.Add("Save settings now", SaveNow)
A_TrayMenu.Add("Auto-save settings", ToggleAutoSave)
A_TrayMenu.Add("Reset to defaults", ResetSettings)
A_TrayMenu.Add()
A_TrayMenu.Add("Start with Windows", ToggleBoot)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit  (Ctrl+Alt+Q)", (*) => ExitApp())
SyncMenu()

; ===================== Hotkeys =====================
^!q::ExitApp()                    ; safe exit
^!d::ToggleDebug()                ; debug info
^!c::NextTheme()                  ; change color
^!Up::ChangeSize(0.1)             ; bigger
^!Down::ChangeSize(-0.1)          ; smaller
^!r::ToggleRipple()               ; click ripple
^!t::ToggleTrail()                ; trail
^!s::ShowSettings()               ; settings window

; ===================== Main loop =====================
; Runs with SetTimer so cursor keeps moving while tray menu or messages are open.
Persistent()
SetTimer(Frame, 8)

; ===================== Feature functions =====================
ToggleDebug() {
    global dbg
    dbg := !dbg
    if (!dbg)
        ToolTip()
}

ToggleRipple(*) {
    global RIPPLE_ON
    RIPPLE_ON := !RIPPLE_ON
    SyncMenu()
    ScheduleSave()
}

ToggleTrail(*) {
    global TRAIL_ON, trailX, trailY
    TRAIL_ON := !TRAIL_ON
    trailX := [], trailY := []
    SyncMenu()
    ScheduleSave()
}

NextTheme(*) {
    global themeIdx, THEMES
    themeIdx := Mod(themeIdx, THEMES.Length) + 1
    ApplyTheme()
    ScheduleSave()
}

ChangeSize(d) {
    global CFG, MIN_USER_SCALE, MAX_USER_SCALE
    CFG["size"] := Min(Round(MAX_USER_SCALE * 100), Max(Round(MIN_USER_SCALE * 100), CFG["size"] + Round(d * 100)))
    SyncDerived()
    RefreshGui()
    ScheduleSave()
}

; Values derived from settings, used in Frame
SyncDerived() {
    global CFG, userScale, HOVER_SCALE
    userScale := CFG["size"] / 100
    HOVER_SCALE := CFG["hover"] / 100
}

; ---------- Tray menu: sync checkmarks ----------
SyncMenu() {
    global RIPPLE_ON, TRAIL_ON, AUTOSAVE, bootEnabled
    if (RIPPLE_ON)
        A_TrayMenu.Check("Click ripple")
    else
        A_TrayMenu.Uncheck("Click ripple")
    if (TRAIL_ON)
        A_TrayMenu.Check("Cursor trail")
    else
        A_TrayMenu.Uncheck("Cursor trail")
    if (AUTOSAVE)
        A_TrayMenu.Check("Auto-save settings")
    else
        A_TrayMenu.Uncheck("Auto-save settings")
    if (bootEnabled)
        A_TrayMenu.Check("Start with Windows")
    else
        A_TrayMenu.Uncheck("Start with Windows")
}

; ---------- Save and load settings ----------
LoadSettings() {
    global RIPPLE_ON, TRAIL_ON, themeIdx, AUTOSAVE, NO_ACCEL, OVR_SPEED
    global SETTINGS_INI, THEMES, CFG, SLIDERS
    if (!FileExist(SETTINGS_INI))
        return
    try {
        RIPPLE_ON := (IniRead(SETTINGS_INI, "Settings", "Ripple", "1") = "1")
        TRAIL_ON  := (IniRead(SETTINGS_INI, "Settings", "Trail", "0") = "1")
        AUTOSAVE  := (IniRead(SETTINGS_INI, "Settings", "AutoSave", "1") = "1")
        NO_ACCEL  := (IniRead(SETTINGS_INI, "Settings", "NoAccel", "1") = "1")
        OVR_SPEED := (IniRead(SETTINGS_INI, "Settings", "OvrSpeed", "0") = "1")
        t := IniRead(SETTINGS_INI, "Settings", "Theme", "1")
        if (IsInteger(t) && Integer(t) >= 1 && Integer(t) <= THEMES.Length)
            themeIdx := Integer(t)
        for sd in SLIDERS {
            v := IniRead(SETTINGS_INI, "Motion", sd[1], sd[5])
            if (IsInteger(v))
                CFG[sd[1]] := Min(sd[4], Max(sd[3], Integer(v)))
        }
    }
}

SaveSettings(*) {
    global RIPPLE_ON, TRAIL_ON, themeIdx, AUTOSAVE, NO_ACCEL, OVR_SPEED
    global SETTINGS_DIR, SETTINGS_INI, CFG, SLIDERS
    try {
        DirCreate(SETTINGS_DIR)
        IniWrite(RIPPLE_ON ? 1 : 0, SETTINGS_INI, "Settings", "Ripple")
        IniWrite(TRAIL_ON ? 1 : 0, SETTINGS_INI, "Settings", "Trail")
        IniWrite(AUTOSAVE ? 1 : 0, SETTINGS_INI, "Settings", "AutoSave")
        IniWrite(NO_ACCEL ? 1 : 0, SETTINGS_INI, "Settings", "NoAccel")
        IniWrite(OVR_SPEED ? 1 : 0, SETTINGS_INI, "Settings", "OvrSpeed")
        IniWrite(themeIdx, SETTINGS_INI, "Settings", "Theme")
        for sd in SLIDERS
            IniWrite(CFG[sd[1]], SETTINGS_INI, "Motion", sd[1])
    } catch {
        return false
    }
    return true
}

; Save with a short delay, so holding a size key does not write to disk thousands of times.
ScheduleSave() {
    global AUTOSAVE
    if (AUTOSAVE)
        SetTimer(SaveSettings, -800)
}

SaveNow(*) {
    global SETTINGS_INI
    if (SaveSettings())
        TrayTip("Settings saved`n" SETTINGS_INI, "Smooth Cursor")
    else
        TrayTip("Could not save settings", "Smooth Cursor", "Icon!")
}

ToggleAutoSave(*) {
    global AUTOSAVE
    AUTOSAVE := !AUTOSAVE
    SaveSettings()
    SyncMenu()
}

ResetSettings(*) {
    global RIPPLE_ON, TRAIL_ON, themeIdx, trailX, trailY, NO_ACCEL, OVR_SPEED, CFG, SLIDERS
    RIPPLE_ON := true
    TRAIL_ON := false
    themeIdx := 1
    NO_ACCEL := true
    OVR_SPEED := false
    trailX := [], trailY := []
    for sd in SLIDERS
        CFG[sd[1]] := sd[5]
    SyncDerived()
    ApplyTheme()
    ApplyMouse()
    SyncMenu()
    RefreshGui()
    ScheduleSave()
}

; ---------- Start with Windows (Scheduled Task with highest privileges, no UAC prompt) ----------
IsBootEnabled() {
    global BOOT_TASK
    try
        return RunWait('schtasks /Query /TN "' BOOT_TASK '"', , "Hide") = 0
    return false
}

ToggleBoot(*) {
    global bootEnabled
    if (bootEnabled) {
        if (DisableBoot())
            bootEnabled := false
        else
            TrayTip("Could not remove the startup task", "Smooth Cursor", "Icon!")
    } else {
        if (EnableBoot())
            bootEnabled := true
        else
            TrayTip("Could not create the startup task", "Smooth Cursor", "Icon!")
    }
    SyncMenu()
}

EnableBoot() {
    global BOOT_TASK, canUIA, uiaExe
    if A_IsCompiled {
        exe := A_ScriptFullPath
        args := ""
    } else {
        exe := canUIA ? uiaExe : A_AhkPath
        args := '"' A_ScriptFullPath '"'
    }
    domain := EnvGet("USERDOMAIN")
    user := (domain != "" ? domain : A_ComputerName) "\" A_UserName

    xml := '<?xml version="1.0" encoding="UTF-16"?>`n'
    xml .= '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">`n'
    xml .= '<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>' XmlEsc(user) '</UserId><Delay>PT5S</Delay></LogonTrigger></Triggers>`n'
    xml .= '<Principals><Principal id="Author"><UserId>' XmlEsc(user) '</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>`n'
    xml .= '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
    xml .= '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled></Settings>`n'
    xml .= '<Actions Context="Author"><Exec><Command>' XmlEsc(exe) '</Command>'
    if (args != "")
        xml .= '<Arguments>' XmlEsc(args) '</Arguments>'
    xml .= '</Exec></Actions></Task>'

    xmlPath := A_Temp "\SmoothCursor_task.xml"
    try FileDelete(xmlPath)
    try {
        FileAppend(xml, xmlPath, "UTF-16")
        rc := RunWait('schtasks /Create /TN "' BOOT_TASK '" /XML "' xmlPath '" /F', , "Hide")
    } catch {
        rc := -1
    }
    try FileDelete(xmlPath)
    return rc = 0
}

DisableBoot() {
    global BOOT_TASK
    try
        return RunWait('schtasks /Delete /TN "' BOOT_TASK '" /F', , "Hide") = 0
    return false
}

XmlEsc(s) {
    s := StrReplace(s, "&", "&amp;")
    s := StrReplace(s, "<", "&lt;")
    s := StrReplace(s, ">", "&gt;")
    return s
}

; ---------- Mouse: pointer acceleration and speed, only while this app is running ----------
GetMouseState() {
    buf := Buffer(12, 0)
    spd := Buffer(4, 0)
    DllCall("SystemParametersInfo", "UInt", 0x0003, "UInt", 0, "Ptr", buf, "UInt", 0)   ; SPI_GETMOUSE
    DllCall("SystemParametersInfo", "UInt", 0x0070, "UInt", 0, "Ptr", spd, "UInt", 0)   ; SPI_GETMOUSESPEED
    return [NumGet(buf, 0, "Int"), NumGet(buf, 4, "Int"), NumGet(buf, 8, "Int"), NumGet(spd, 0, "Int")]
}

SetMouseAccel(t1, t2, acc) {
    buf := Buffer(12, 0)
    NumPut("Int", t1, "Int", t2, "Int", acc, buf)
    ; fWinIni = 0 → apply only to this session, do not save to registry
    DllCall("SystemParametersInfo", "UInt", 0x0004, "UInt", 0, "Ptr", buf, "UInt", 0)   ; SPI_SETMOUSE
}

SetMouseSpeed(v) {
    if (v < 1 || v > 20)
        return
    DllCall("SystemParametersInfo", "UInt", 0x0071, "UInt", 0, "Ptr", v, "UInt", 0)     ; SPI_SETMOUSESPEED
}

; Keep original values in memory and INI.
; If the app crashes, the next run restores them.
BackupMouse() {
    global mouseOrig, SETTINGS_DIR, SETTINGS_INI
    mouseOrig := GetMouseState()
    try {
        DirCreate(SETTINGS_DIR)
        IniWrite(1, SETTINGS_INI, "Backup", "Active")
        IniWrite(mouseOrig[1], SETTINGS_INI, "Backup", "T1")
        IniWrite(mouseOrig[2], SETTINGS_INI, "Backup", "T2")
        IniWrite(mouseOrig[3], SETTINGS_INI, "Backup", "Acc")
        IniWrite(mouseOrig[4], SETTINGS_INI, "Backup", "Speed")
    }
}

RecoverMouseBackup() {
    global SETTINGS_INI
    try {
        if (IniRead(SETTINGS_INI, "Backup", "Active", "0") != "1")
            return
        t1  := IniRead(SETTINGS_INI, "Backup", "T1", "x")
        t2  := IniRead(SETTINGS_INI, "Backup", "T2", "x")
        acc := IniRead(SETTINGS_INI, "Backup", "Acc", "x")
        spd := IniRead(SETTINGS_INI, "Backup", "Speed", "x")
        if (IsInteger(t1) && IsInteger(t2) && IsInteger(acc) && IsInteger(spd)) {
            SetMouseAccel(Integer(t1), Integer(t2), Integer(acc))
            SetMouseSpeed(Integer(spd))
        }
        IniWrite(0, SETTINGS_INI, "Backup", "Active")
    }
}

ApplyMouse() {
    global mouseOrig, NO_ACCEL, OVR_SPEED, CFG
    if (!IsObject(mouseOrig))
        return
    SetMouseAccel(mouseOrig[1], mouseOrig[2], NO_ACCEL ? 0 : mouseOrig[3])
    SetMouseSpeed(OVR_SPEED ? CFG["pointerSpeed"] : mouseOrig[4])
}

RestoreMouse() {
    global mouseOrig, SETTINGS_INI
    if (!IsObject(mouseOrig))
        return
    SetMouseAccel(mouseOrig[1], mouseOrig[2], mouseOrig[3])
    SetMouseSpeed(mouseOrig[4])
    mouseOrig := ""
    try IniWrite(0, SETTINGS_INI, "Backup", "Active")
}

; ---------- Settings window ----------
CfgText(key) {
    global CFG, SLIDERS
    for sd in SLIDERS {
        if (sd[1] = key)
            return CFG[key] . sd[6]
    }
    return CFG[key]
}

AddSliderRow(key) {
    global setGui, uiCtrls, CFG, SLIDERS
    for sd in SLIDERS {
        if (sd[1] != key)
            continue
        setGui.AddText("xm w400", sd[2])
        sl := setGui.AddSlider("xm w320 Range" sd[3] "-" sd[4] " ToolTip", CFG[key])
        tx := setGui.AddText("x+10 yp+3 w70", CfgText(key))
        uiCtrls[key] := [sl, tx]
        sl.OnEvent("Change", SliderChanged.Bind(key, tx))
        return
    }
}

SliderChanged(key, tx, ctrl, *) {
    global CFG, OVR_SPEED
    CFG[key] := ctrl.Value
    tx.Text := CfgText(key)
    SyncDerived()
    if (key = "pointerSpeed" && OVR_SPEED)
        ApplyMouse()
    ScheduleSave()
}

AccelClicked(ctrl, *) {
    global NO_ACCEL
    NO_ACCEL := (ctrl.Value = 1)
    ApplyMouse()
    ScheduleSave()
}

SpeedOverrideClicked(ctrl, *) {
    global OVR_SPEED, uiCtrls
    OVR_SPEED := (ctrl.Value = 1)
    uiCtrls["pointerSpeed"][1].Enabled := OVR_SPEED
    ApplyMouse()
    ScheduleSave()
}

ResetMotion(*) {
    global CFG, SLIDERS
    for sd in SLIDERS {
        if (sd[1] != "pointerSpeed")
            CFG[sd[1]] := sd[5]
    }
    SyncDerived()
    RefreshGui()
    ScheduleSave()
}

RefreshGui() {
    global setGui, uiCtrls, CFG, NO_ACCEL, OVR_SPEED, cbAccel, cbSpeed
    if (!IsObject(setGui))
        return
    for key, pair in uiCtrls {
        pair[1].Value := CFG[key]
        pair[2].Text := CfgText(key)
    }
    cbAccel.Value := NO_ACCEL ? 1 : 0
    cbSpeed.Value := OVR_SPEED ? 1 : 0
    uiCtrls["pointerSpeed"][1].Enabled := OVR_SPEED
}

SettingsClose(g, *) {
    g.Hide()
    return 1
}

ShowSettings(*) {
    global setGui, uiCtrls, SLIDERS, cbAccel, cbSpeed, NO_ACCEL, OVR_SPEED
    if (IsObject(setGui)) {
        RefreshGui()
        setGui.Show()
        return
    }
    setGui := Gui("+MinimizeBox", "Smooth Cursor - Settings")
    setGui.SetFont("s9", "Segoe UI")
    setGui.MarginX := 16
    setGui.MarginY := 12
    setGui.OnEvent("Close", SettingsClose)

    setGui.SetFont("s9 bold")
    setGui.AddText("xm w400", "Mouse  (applies only while this app is running)")
    setGui.SetFont("s9 norm")
    cbAccel := setGui.AddCheckbox("xm w400", "Disable pointer acceleration (Enhance pointer precision)")
    cbAccel.Value := NO_ACCEL ? 1 : 0
    cbAccel.OnEvent("Click", AccelClicked)
    cbSpeed := setGui.AddCheckbox("xm w400", "Override Windows pointer speed")
    cbSpeed.Value := OVR_SPEED ? 1 : 0
    cbSpeed.OnEvent("Click", SpeedOverrideClicked)
    AddSliderRow("pointerSpeed")
    uiCtrls["pointerSpeed"][1].Enabled := OVR_SPEED

    setGui.SetFont("s9 bold")
    setGui.AddText("xm w400 y+16", "Cursor motion")
    setGui.SetFont("s9 norm")
    for sd in SLIDERS {
        if (sd[1] != "pointerSpeed")
            AddSliderRow(sd[1])
    }

    btnReset := setGui.AddButton("xm y+16 w140", "Reset motion")
    btnReset.OnEvent("Click", ResetMotion)
    btnClose := setGui.AddButton("x+10 w100 Default", "Close")
    btnClose.OnEvent("Click", (*) => SettingsClose(setGui))
    setGui.Show()
}

ApplyTheme() {
    global brush, pen, ipen, THEMES, themeIdx
    DllCall("gdiplus\GdipSetSolidFillColor", "Ptr", brush, "UInt", THEMES[themeIdx][1])
    DllCall("gdiplus\GdipSetPenColor", "Ptr", pen, "UInt", THEMES[themeIdx][2])
    DllCall("gdiplus\GdipSetPenColor", "Ptr", ipen, "UInt", THEMES[themeIdx][1])
}

; I-beam lines, used when the cursor is over text
IBeamLines(p) {
    global gfx, baseSize
    hh := 0.5 * baseSize
    sw := 0.17 * baseSize
    DllCall("gdiplus\GdipDrawLine", "Ptr", gfx, "Ptr", p, "Float", 0, "Float", -hh, "Float", 0, "Float", hh)
    DllCall("gdiplus\GdipDrawLine", "Ptr", gfx, "Ptr", p, "Float", -sw, "Float", -hh, "Float", sw, "Float", -hh)
    DllCall("gdiplus\GdipDrawLine", "Ptr", gfx, "Ptr", p, "Float", -sw, "Float", hh, "Float", sw, "Float", hh)
}

; Spinner arc, used for Loading state
BusyArc(p, startAng) {
    global gfx, baseSize
    r := 0.42 * baseSize
    DllCall("gdiplus\GdipDrawArc", "Ptr", gfx, "Ptr", p, "Float", -r, "Float", -r
          , "Float", 2 * r, "Float", 2 * r, "Float", startAng, "Float", 270)
}

; ===================== Main frame =====================
Frame() {
    global
    DllCall("QueryPerformanceCounter", "Int64*", &tNow := 0)
    dt := (tNow - tLast) / qpf
    tLast := tNow
    if (dt <= 0)
        return
    if (dt > 0.05)
        dt := 0.05

    ; --- Mouse state and cursor type ---
    DllCall("GetCursorInfo", "Ptr", ci)
    flags := NumGet(ci, 4, "UInt")
    hCur  := NumGet(ci, 8, "Ptr")
    DllCall("GetCursorPos", "Ptr", pt)
    mx    := NumGet(pt, 0, "Int")
    my    := NumGet(pt, 4, "Int")

    hHand  := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")
    hIBeam := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32513, "Ptr")
    hWait  := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32514, "Ptr")
    hApp   := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32650, "Ptr")
    isHand  := (hCur = hHand || hCur = hHandOld)
    isIBeam := (hCur = hIBeam || hCur = hIBeamOld)
    isBusy  := (hCur = hWait || hCur = hWaitOld || hCur = hApp || hCur = hAppOld)
    mode    := isBusy ? 2 : (isIBeam ? 1 : 0)       ; 0=arrow, 1=I-beam, 2=spinner
    visible := (flags & 1) != 0

    ; Shape change: small pop
    if (mode != lastMode) {
        sc := 0.6
        vs := 0
        lastMode := mode
    }

    ; --- Click: record ripple ---
    btnDown := GetKeyState("LButton", "P") || GetKeyState("RButton", "P")
    if (btnDown && !wasDown && visible && RIPPLE_ON)
        ripples.Push([mx, my, A_TickCount])
    wasDown := btnDown

    ; --- Mouse speed, filtered ---
    k := 1 - Exp(-dt / 0.03)          ; faster filter -> detect mouse speed sooner
    mvx += ((mx - lastMx) / dt - mvx) * k
    mvy += ((my - lastMy) / dt - mvy) * k
    lastMx := mx, lastMy := my
    speed  := Sqrt(mvx * mvx + mvy * mvy)
    moving := (speed > ROTATE_MIN_SPEED)

    ; --- Rotation target ---
    if (mode = 0) {
        if (moving) {
            desired := Atan2(mvy, mvx) * 57.29577951308232 + 90
            ta := ang + Mod(Mod(desired - ang, 360) + 540, 360) - 180
        }
    } else {
        ; I-beam and spinner stay straight
        rem := Mod(ang, 360)
        if (rem > 180) {
            rem -= 360
        } else if (rem < -180) {
            rem += 360
        }
        ta := ang - rem
    }
    if (ang > 720) {
        ang -= 720, ta -= 720
    } else if (ang < -720) {
        ang += 720, ta += 720
    }

    ; --- Size target ---
    ts := (mode = 0 && isHand) ? HOVER_SCALE : (moving ? MOVE_SCALE : 1)
    if (visible && btnDown)
        ts *= PRESS_SCALE

    ; --- Spring physics, parameters from settings ---
    smoothMs := CFG["smoothMs"]
    zeta := CFG["bounce"] / 100
    rotF := CFG["rotSmooth"] / 100
    if (smoothMs >= 5) {
        ; The faster the mouse moves, the stiffer the spring becomes, so lag is lower.
        omegaP := (3000 / smoothMs) * (1 + CFG["boost"] / 100 * 3 * Min(speed / 2000, 1))
    } else {
        omegaP := 0
    }
    posK := omegaP * omegaP
    posC := 2 * zeta * omegaP
    rotKk := ROT_K * rotF * rotF
    rotCc := ROT_C * rotF
    omegaMax := Max(omegaP, Sqrt(rotKk), Sqrt(SCL_K))
    n := Min(300, Max(Ceil(dt / 0.008), Ceil(dt * omegaMax / 0.4)))
    h := dt / n
    Loop n {
        if (omegaP > 0) {
            vx += (posK * (mx - px) - posC * vx) * h
            vy += (posK * (my - py) - posC * vy) * h
            px += vx * h
            py += vy * h
        }
        va += (rotKk * (ta - ang) - rotCc * va) * h
        ang += va * h
        vs += (SCL_K * (ts - sc) - SCL_C * vs) * h
        sc += vs * h
    }
    if (omegaP = 0) {
        px := mx, py := my, vx := 0, vy := 0
    }

    ; Distance limit: cursor never lags more than maxLag pixels behind the mouse.
    if (CFG["maxLag"] > 0) {
        lagLimit := CFG["maxLag"] * dpi
        ddx := px - mx
        ddy := py - my
        lagDist := Sqrt(ddx * ddx + ddy * ddy)
        if (lagDist > lagLimit) {
            lagF := lagLimit / lagDist
            px := mx + ddx * lagF
            py := my + ddy * lagF
        }
    }

    ; --- Opacity, fade in/out ---
    targetOp := visible ? 255 : 0
    opac += (targetOp - opac) * (1 - Exp(-dt / 0.04))
    if (Abs(targetOp - opac) < 0.5)
        opac := targetOp
    if (!visible && opac < 4) {          ; when hidden, jump to the mouse
        px := mx, py := my, vx := 0, vy := 0
    }

    ; --- Do not render only when fully hidden ---
    if (!visible && opac = 0) {
        if (dbg)
            ToolTip("HIDDEN  hCur=" hCur "`nHand=" hHand " / old " hHandOld
                  . "`nA_Cursor=" A_Cursor, mx + 30, my + 30)
        return
    }

    ; --- Keep overlay above all windows, checked every 50 ms ---
    if (A_TickCount - lastTopCheck > 50) {
        lastTopCheck := A_TickCount
        ; GW_HWNDPREV = 3 -> if another window is above us, make topmost again
        if (DllCall("GetWindow", "Ptr", hwnd, "UInt", 3, "Ptr"))
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
    }

    ; --- Record trail path ---
    if (TRAIL_ON) {
        trailTick += 1
        if (Mod(trailTick, 2) = 0) {
            trailX.Push(px)
            trailY.Push(py)
            if (trailX.Length > TRAIL_N) {
                trailX.RemoveAt(1)
                trailY.RemoveAt(1)
            }
        }
    }

    ; --- Remove finished ripples ---
    while (ripples.Length && A_TickCount - ripples[1][3] > RIPPLE_MS)
        ripples.RemoveAt(1)

    ; --- Render ---
    eff     := Max(sc * userScale, 0.05)
    originX := Floor(px) - half
    originY := Floor(py) - half
    cx := half + (px - Floor(px))
    cy := half + (py - Floor(py))
    themeFill   := THEMES[themeIdx][1] & 0xFFFFFF
    themeStroke := THEMES[themeIdx][2] & 0xFFFFFF

    DllCall("gdiplus\GdipGraphicsClear", "Ptr", gfx, "UInt", 0x00000000)
    DllCall("gdiplus\GdipResetWorldTransform", "Ptr", gfx)

    ; Trail
    if (TRAIL_ON && trailX.Length > 1) {
        nTr := trailX.Length
        Loop nTr {
            trI := A_Index
            frac := trI / nTr
            DllCall("gdiplus\GdipSetSolidFillColor", "Ptr", trBrush, "UInt", (Round(110 * frac) << 24) | themeFill)
            trR := (1.5 + 4.5 * frac) * dpi * userScale
            DllCall("gdiplus\GdipFillEllipse", "Ptr", gfx, "Ptr", trBrush
                  , "Float", trailX[trI] - originX - trR, "Float", trailY[trI] - originY - trR
                  , "Float", 2 * trR, "Float", 2 * trR)
        }
    }

    ; Click ripple
    for ripItem in ripples {
        ripT := (A_TickCount - ripItem[3]) / RIPPLE_MS
        if (ripT >= 1)
            continue
        ripE := 1 - (1 - ripT) ** 3
        ripR := (6 + 30 * ripE) * dpi
        ripA := Round(220 * (1 - ripT))
        ripX := ripItem[1] - originX
        ripY := ripItem[2] - originY
        ; outer ring uses outline color, inner ring uses main color
        DllCall("gdiplus\GdipSetPenColor", "Ptr", rpen, "UInt", (ripA << 24) | themeStroke)
        DllCall("gdiplus\GdipSetPenWidth", "Ptr", rpen, "Float", 4 * dpi)
        DllCall("gdiplus\GdipDrawEllipse", "Ptr", gfx, "Ptr", rpen
              , "Float", ripX - ripR, "Float", ripY - ripR, "Float", 2 * ripR, "Float", 2 * ripR)
        DllCall("gdiplus\GdipSetPenColor", "Ptr", rpen, "UInt", (ripA << 24) | themeFill)
        DllCall("gdiplus\GdipSetPenWidth", "Ptr", rpen, "Float", 2 * dpi)
        DllCall("gdiplus\GdipDrawEllipse", "Ptr", gfx, "Ptr", rpen
              , "Float", ripX - ripR, "Float", ripY - ripR, "Float", 2 * ripR, "Float", 2 * ripR)
    }

    ; Cursor itself: shadow + main shape
    busyAng := Mod(A_TickCount * 0.4, 360)
    Loop 2 {
        isShadow := (A_Index = 1)
        DllCall("gdiplus\GdipResetWorldTransform", "Ptr", gfx)
        DllCall("gdiplus\GdipTranslateWorldTransform", "Ptr", gfx, "Float", cx, "Float", cy + (isShadow ? 2.5 * dpi : 0), "Int", 0)
        DllCall("gdiplus\GdipRotateWorldTransform", "Ptr", gfx, "Float", ang, "Int", 0)
        DllCall("gdiplus\GdipScaleWorldTransform", "Ptr", gfx, "Float", eff, "Float", eff, "Int", 0)

        if (mode = 0) {
            ; ---- Arrow ----
            if (isShadow) {
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", shPen, "Float", 7 * dpi / eff)
                DllCall("gdiplus\GdipDrawPolygon", "Ptr", gfx, "Ptr", shPen, "Ptr", pts, "Int", 4)
                DllCall("gdiplus\GdipFillPolygon", "Ptr", gfx, "Ptr", shBrush, "Ptr", pts, "Int", 4, "Int", 0)
            } else {
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", pen, "Float", STROKE_WIDTH * 2 * dpi / eff)
                DllCall("gdiplus\GdipDrawPolygon", "Ptr", gfx, "Ptr", pen, "Ptr", pts, "Int", 4)
                DllCall("gdiplus\GdipFillPolygon", "Ptr", gfx, "Ptr", brush, "Ptr", pts, "Int", 4, "Int", 0)
            }
        } else if (mode = 1) {
            ; ---- I-beam ----
            if (isShadow) {
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", shPen, "Float", 7 * dpi / eff)
                IBeamLines(shPen)
            } else {
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", pen, "Float", (2.2 + 2 * STROKE_WIDTH) * dpi / eff)
                IBeamLines(pen)
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", ipen, "Float", 2.2 * dpi / eff)
                IBeamLines(ipen)
            }
        } else {
            ; ---- Loading spinner ----
            if (isShadow) {
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", shPen, "Float", 7 * dpi / eff)
                BusyArc(shPen, busyAng)
            } else {
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", pen, "Float", (3.2 + 2 * STROKE_WIDTH) * dpi / eff)
                BusyArc(pen, busyAng)
                DllCall("gdiplus\GdipSetPenWidth", "Ptr", ipen, "Float", 3.2 * dpi / eff)
                BusyArc(ipen, busyAng)
            }
        }
    }
    DllCall("gdiplus\GdipFlush", "Ptr", gfx, "Int", 1)

    NumPut("Int", originX, "Int", originY, ptDst)
    NumPut("UChar", 0, "UChar", 0, "UChar", Round(opac), "UChar", 1, blend)
    ok := DllCall("UpdateLayeredWindow", "Ptr", hwnd, "Ptr", 0, "Ptr", ptDst, "Ptr", szBuf
          , "Ptr", hdc, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2)

    if (dbg)
        ToolTip("mouse=" mx "," my "  cursor=" Round(px) "," Round(py)
              . "`nopac=" Round(opac) " scale=" Round(eff, 2) " ang=" Round(ang) " mode=" mode
              . "`nULW ok=" ok " err=" A_LastError
              . "`nhCur=" hCur " hand=" isHand " ibeam=" isIBeam " busy=" isBusy, mx + 30, my + 30)
}

; ===================== Helper functions =====================
BlankAllCursors() {
    global CURSOR_IDS
    for id in CURSOR_IDS
        BlankCursor(id)
}

Maintain() {
    global hwnd
    BlankAllCursors()
    ; Bring overlay back above all windows: HWND_TOPMOST | NOSIZE | NOMOVE | NOACTIVATE
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
}

CrashRestore(e, mode) {
    ; If the script crashed, restore Windows cursors and mouse settings.
    DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)
    RestoreMouse()
    return 0
}

BlankCursor(id) {
    andMask := Buffer(128, 0xFF)
    xorMask := Buffer(128, 0)
    hCur := DllCall("CreateCursor", "Ptr", 0, "Int", 0, "Int", 0, "Int", 32, "Int", 32
                  , "Ptr", andMask, "Ptr", xorMask, "Ptr")
    DllCall("SetSystemCursor", "Ptr", hCur, "UInt", id)
}

Atan2(y, x) {
    static PI := 3.141592653589793
    if (x > 0)
        return ATan(y / x)
    if (x < 0)
        return ATan(y / x) + (y >= 0 ? PI : -PI)
    return y > 0 ? PI / 2 : (y < 0 ? -PI / 2 : 0)
}

Cleanup(*) {
    global
    SetTimer(Frame, 0)
    SetTimer(Maintain, 0)
    RestoreMouse()                                                                  ; restore acceleration and mouse speed
    DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)  ; restore system cursors
    DllCall("winmm\timeEndPeriod", "UInt", 1)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    DllCall("gdiplus\GdipDeletePen", "Ptr", ipen)
    DllCall("gdiplus\GdipDeletePen", "Ptr", shPen)
    DllCall("gdiplus\GdipDeletePen", "Ptr", rpen)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", shBrush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", trBrush)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gfx)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", obm)
    DllCall("DeleteObject", "Ptr", hbm)
    DllCall("DeleteDC", "Ptr", hdc)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
}