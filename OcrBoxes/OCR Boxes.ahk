#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ============================================================================
;  OCR Boxes - up to four see-through boxes you drag over on-screen text.  Click a box's lock and it goes invisible, clicks pass
;  through it to the game, and everything that appears inside it is read aloud, in order, with nothing skipped.
;
;    +  /  -          add a box (OCR Box 1..4) / remove the highest one       drag a box by its body, resize it by its edges
;    lock icon        top-right corner of a box (or the 1 2 3 4 buttons on the bar when a box is invisible)
;    Play/Pause/Stop  Pause holds the queue (and freezes an SAPI sentence); Stop cuts the voice and clears the queue
;    Read with        Windows OCR (built in) | RapidOCR (Python helper) | a local vision model (Ollama / LM Studio)
;    Voice            Edge natural voices through SAPI | Kokoro Player | ElevenLabs (cloud)
;
;  How nothing gets lost: every locked box is looked at every 100 ms (an 80x40 picture, ~10 ms).  When it changes and then stops
;  changing, a full-resolution snapshot is taken at once and put in a queue; the reader works through the snapshots in order, even
;  if the text on screen has already gone.  What it reads goes into one strict first-in first-out queue per box.
;
;  Settings: "OCR Boxes.ini" next to this script.  Log: %LOCALAPPDATA%\OcrBoxes\boxes.log  (timings only, never the text).
;  Check:  AutoHotkey64.exe "OCR Boxes.ahk" --selftest result.txt
; ============================================================================

; Per-monitor v2: from here on every coordinate this script reads or sets is a physical pixel of the virtual desktop, so a box that
; sits on a 150 % laptop panel and one on a 100 % 32-inch monitor are captured exactly where they are drawn.
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
CoordMode "Mouse", "Screen"
SetWorkingDir A_ScriptDir

#include .\Lib\BoxLogic.ahk
#include .\Lib\BoxIO.ahk
#include .\Lib\Speakers.ahk
#include .\Lib\BoxState.ahk
#include .\Lib\LunaReceipt.ahk
#include .\Lib\GameProfiles.ahk
#include .\Lib\CapturePicker.ahk
#include .\Lib\DesktopReader.ahk
#include .\Lib\EdgeBrowserReader.ahk
#include .\Lib\BoxVoices.ahk
#include ..\game-voice-reader\Lib\OCR.ahk

; ---- state ------------------------------------------------------------------------------------------------------------------
global SelfTest := (A_Args.Length >= 1 && A_Args[1] = "--selftest")
global E2E := (A_Args.Length >= 1 && A_Args[1] = "--e2e")     ; --e2e out.txt engine seconds barX barY x y w h [x y w h ...]: an unattended end-to-end run (see E2ERun)
global E2EOut := ""
global E2EEngine := "windows"
global E2ESeconds := 20
global E2EBar := {x: 0, y: 0}
global E2EBoxes := []
global E2ESpoken := []
global E2EStarted := 0
global E2EFixtures := []
global E2EFailure := ""
global MaxBoxes := 4
global Boxes := [0, 0, 0, 0]               ; OcrBox objects by number (0 = free slot)
global Lanes := []                         ; one Lane per box, then Luna Translator
global Rdr := 0
global Pending := []                       ; snapshots waiting to be read, oldest first
global Job := 0                            ; the RapidOCR / vision-model request in flight
global PendingCap := 24                    ; snapshots kept waiting at most (see DropForOverflow)
global State := "playing"                  ; playing | paused | stopped
global Speakers := Map()
global Spk := 0
global Speaking := false
global SpeechEpoch := 0
global QueueEpoch := 0
global SpeakingSince := 0
global RetryAt := 0
global Bar := 0
global BarCtl := 0
global OcrLang := ""
global OcrKeys := ["windows", "rapid", "vlm"]
global VoiceKeys := ["edge", "sapi", "kokoro", "eleven"]
global VoiceLabels := ["Edge natural voices (online)", "Edge natural voices (SAPI adapter)", "Kokoro Player", "ElevenLabs (cloud)"]      ; same order as VoiceKeys
global VoiceIds := []
global LunaState := "off"                  ; off | waiting | on
global LastLunaPoll := 0
global LunaRetryAt := 0
global LunaDisconnectedAt := 0
global TickBusy := false
global SampleBusy := false
global SampleMs := 0
global SampleCount := 0
global LastReport := 0
; OCR passes, tried in order until one reads well (as in Game Voice Reader)
global Passes := [{s: 2, g: false, i: false}, {s: 3, g: true, i: true}, {s: 3, g: true, i: false}, {s: 4, g: false, i: false}]

global Results := ""

Main() {
    global Rdr, State, VoiceKeys, VoiceLabels, OcrKeys
    Cfg.Ensure()
    GameSession.Enabled := !SelfTest && Cfg.Get("capture", "mode", "general") = "games"
    State := "stopped" ; neither mode captures or speaks until the user starts it
    if !GameSession.Enabled && !E2E {
        OcrKeys := ["windows","rapid"]
        if Cfg.Get("ocr","engine","windows") != "windows" && Cfg.Get("ocr","engine","") != "rapid"
            Cfg.Set("ocr","engine","rapid")
        DesktopReader.Init()
        VoiceKeys := ["browser","kokoro","sapi","eleven"]
        VoiceLabels := ["Edge Read Aloud (Game Voice Reader)","Kokoro Player (default output)","Edge natural voices (SAPI adapter)","ElevenLabs (cloud)"]
        if Cfg.Get("voice","engine","edge") = "edge"
            Cfg.Set("voice","engine","browser")
    }
    if GameSession.Enabled {
        GameProfiles.Load()
        State := "stopped"
        VoiceKeys := ["kokoro"]
        VoiceLabels := ["Kokoro Player (CPU game reader)"]
    }
    if GameSession.Enabled {
        Cfg.Set("ocr","engine","windows")
        Cfg.Set("voice","engine","kokoro")
        Cfg.Set("voice","kokoroVoice","af_heart")
    }
    SnapshotFiles.ReapOld()
    OnError(OnUnhandled)
    OnExit(Shutdown)
    Loop MaxBoxes
        Lanes.Push(Lane("OCR Box " A_Index))
    Lanes.Push(Lane("Luna Translator", 200, 5000))
    Rdr := Reader(Lanes, Cfg.Get("reader", "order", "box"))
    PickOcrLanguage()
    InitSpeakers()
    TrimVoiceLists()
    BuildTray()
    BuildBar()
    if GameSession.Enabled
        GameSession.InstallForegroundGuard()
    OnMessage(0x201, OnLButtonDown)
    ; Two timers: the looks at the boxes (SampleTick) must keep their 100 ms beat while a slow step of the reading loop (Tick) is busy.
    SetTimer(SampleTick, Integer(Cfg.Num("watch", "pollMs", 100, 50, 1000)))
    SetTimer(Tick, Integer(Cfg.Num("watch", "pollMs", 100, 50, 1000)))
    if GameSession.Enabled {
        SetTimer(ObjBindMethod(GameSession,"Watch"), 50)
        Hotkey("^!F8", (*) => OnPause())
        Hotkey("^!F9", (*) => OnPlay())
        Hotkey("^!F10", (*) => GameSession.Suspend("stop-hotkey"))
    }
    Log("start ocr=" Cfg.Get("ocr", "engine", "windows") " voice=" Cfg.Get("voice", "engine", "edge") " ocrLang=" (OcrLang = "" ? "default" : OcrLang) " dpiContext=" DllCall("GetThreadDpiAwarenessContext", "ptr"))
}

; ---- start-up pieces ----------------------------------------------------------------------------------------------------------
PickOcrLanguage() {
    global OcrLang
    OcrLang := Cfg.Get("ocr", "lang", "")
    if OcrLang != ""
        return
    try {
        langs := OCR.GetAvailableLanguages()
        if RegExMatch(langs, "m)^en-US\s*$")
            OcrLang := "en-US"
    }
}

InitSpeakers() {
    if GameSession.Enabled {
        Speakers["kokoro"] := KokoroSpeaker()
        ChooseSpeaker("kokoro")
        return
    }
    try
        Speakers["sapi"] := SapiSpeaker()
    catch as e
        Log("SAPI is not available: " e.Message)
    Speakers["edge"] := EdgeSpeaker()
    Speakers["browser"] := EdgeBrowserSpeaker()
    Speakers["kokoro"] := RoutedKokoroSpeaker()
    Speakers["eleven"] := ElevenSpeaker()
    key := Cfg.Get("voice", "engine", "edge")
    if !Speakers.Has(key)
        key := "kokoro"
    if key = "sapi" && !SapiUsable() {                            ; none of Ava / Brian / Ryan is installed: never fall back to a classic Windows voice
        Log("no allowed SAPI voice (Edge Ava Multilingual / Brian Multilingual / Ryan) is installed - using the Edge voices through the helper")
        key := "browser"
        Cfg.Set("voice", "engine", key)
    }
    if key = "eleven" && ElevenProblem() != "" {                 ; a paid service that is not set up must not be the voice at start-up
        Log("ElevenLabs is not set up (" ElevenProblem() ") - using the Edge voices through the helper")
        key := "browser"
        Cfg.Set("voice", "engine", key)
    }
    ChooseSpeaker(key)
}

; Edge voices run in the helper and need a connection to Microsoft's servers (about 0.3 s to set up).  A snapshot means a line will probably be spoken soon, so the
; helper is asked to open that connection now (at most every 1.5 s; it never waits for the answer).  Other voice engines have no Warm() and are left alone.
WarmSpeech() {
    static last := 0
    if A_TickCount - last < 1500 || !IsObject(Spk)
        return
    last := A_TickCount
    try {
        if Spk.HasMethod("Warm")
            Spk.Warm()
    }
}

; True when SAPI exists and at least one of the three allowed Edge voices is installed for it.
SapiUsable() {
    if !Speakers.Has("sapi")
        return false
    try
        return Speakers["sapi"].Voices().Length > 0
    return false
}

; "" when ElevenLabs can be used, otherwise what is missing: a voice id in OCR Boxes.ini and an API key (ELEVENLABS_API_KEY, or the first line of
; %APPDATA%\PixelCompanions\elevenlabs.key).  The key itself is never read here.  ElevenLabs is a paid cloud service.
ElevenProblem() {
    if Trim(Cfg.Get("eleven", "voiceId", "")) = ""
        return "no voice id ([eleven] voiceId in OCR Boxes.ini)"
    if EnvGet("ELEVENLABS_API_KEY") = "" && !FileExist(A_AppData "\PixelCompanions\elevenlabs.key")
        return "no API key (set ELEVENLABS_API_KEY, or save it as the first line of %APPDATA%\PixelCompanions\elevenlabs.key)"
    return ""
}

; The voice list offers only engines that can speak on this PC: the Edge voices through the SAPI adapter when one of Ava / Brian / Ryan is installed for SAPI
; (the adapter is not part of OCR Boxes), and ElevenLabs when its key and voice id are set.  Edge (online) and Kokoro Player are always listed.
TrimVoiceLists() {
    for key in ["sapi", "eleven"] {
        i := PositionOf(VoiceKeys, key)
        if !i
            continue
        if (key = "sapi" && SapiUsable()) || (key = "eleven" && ElevenProblem() = "")
            continue
        VoiceKeys.RemoveAt(i)
        VoiceLabels.RemoveAt(i)
        Log("voice engine " key " is not offered: " (key = "sapi" ? "none of Ava / Brian / Ryan is installed for SAPI" : ElevenProblem()))
    }
}

ChooseSpeaker(key) {
    global Spk
    Spk := Speakers[key]
    if key = "sapi" {
        ; the saved voice only counts when it is one of the three allowed ones; otherwise the first allowed voice that is installed
        if !Spk.SetVoice(Cfg.Get("voice", "sapiVoice", ""))
            for name in Spk.Voices()
                if Spk.SetVoice(name)
                    break
        Spk.SetRate(Cfg.Num("voice", "sapiRate", 0, -10, 10))
    } else if key = "edge" {
        if !Spk.SetVoice(Cfg.Get("voice", "edgeVoice", "ava"))      ; only ava / brian / ryan are accepted; anything else in the file is ignored
            Spk.SetVoice("ava")
        Spk.rate := Integer(Cfg.Num("voice", "edgeRate", 0, -50, 100))
    } else if key = "kokoro" {
        Spk.voice := Cfg.Get("voice", "kokoroVoice", "")
        Spk.speed := Cfg.Num("voice", "kokoroSpeed", 1.0, 0.5, 2.0)
    }
}

BuildTray() {
    A_TrayMenu.Delete()
    A_IconTip := "OCR Boxes"
    A_TrayMenu.Add("Show the control bar", (*) => Bar.Show())
    A_TrayMenu.Add("Open settings file", (*) => Run('notepad.exe "' Cfg.File '"'))
    A_TrayMenu.Add("Open log", (*) => Run('notepad.exe "' Logger.File '"'))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add("Exit", (*) => ExitApp())
}

OnUnhandled(e, mode) {
    if E2E {
        global E2EFailure
        E2EFailure := e.Message
        E2EFinish()
    }
    Log("unhandled error: " e.Message " (" e.What ", line " e.Line ")")
    SetStatus("An error was logged - see the log (tray menu > Open log).")
    try {
        if IsObject(Bar) && !DllCall("IsWindowVisible", "ptr", Bar.Hwnd, "int")
            Bar.Show("NoActivate")                               ; an error before the first show must never leave a running program with no window (10 Oct 2026)
    }
    return 1
}

Shutdown(*) {
    if GameSession.Enabled
        GameSession.Suspend("exit", true)
    if GameSession.Enabled
        GameSession.RemoveForegroundGuard()
    try {
        Bar.GetPos(&x, &y)
        Cfg.Set("bar", "x", x)
        Cfg.Set("bar", "y", y)
    }
    CancelOcrJob()
    SnapshotFiles.Cleanup()
    try Spk.Stop()
    if !GameSession.Enabled
        DesktopReader.Cleanup()
    BoxState.Set("idle")
    if LunaState != "off"
        try Http("POST", Helper.Url "/luna/stop", "{}", 1000)
    for b in Boxes
        if b
            b.Destroy()
    for item in Pending
        item.hbm := ""
}

; ---- one see-through box --------------------------------------------------------------------------------------------------------
class OcrBox {
    static Colors := ["FFF3A6", "BDF2D5", "BBDDFF", "FFC9E3"]
    static GenSeq := 0
    ; A new number every time a box is locked, unlocked or created: a late answer for an old position can never match a new one.
    static NextGen() {
        OcrBox.GenSeq += 1
        return OcrBox.GenSeq
    }
    __New(index, x, y, w, h) {
        this.index := index
        this.locked := false
        this.gen := OcrBox.NextGen()
        this.rect := 0
        this.haveRef := false
        this.lastD := 0
        this.reverts := 0
        this.sampleFails := 0
        this.snapRetries := 0
        this.armAt := 0
        changeFrac := Cfg.Num("watch", "changePercent", 1.5, 0.1, 50) / 100
        settleFrac := Cfg.Num("watch", "settlePercent", 0.06, 0, 10) / 100
        settleLooks := Integer(Cfg.Num("watch", "settleLooks", 2, 1, 10))
        maxSettle := Integer(Cfg.Num("watch", "maxSettleMs", 2500, 500, 20000))
        this.tracker := ChangeTracker(changeFrac, settleFrac, settleLooks, maxSettle)
        this.ref := Buffer(SigSize.Bytes, 0)
        this.prev := Buffer(SigSize.Bytes, 0)
        this.cur := Buffer(SigSize.Bytes, 0)
        ; -DPIScale: every number below is a physical pixel.  E0x08000000 = WS_EX_NOACTIVATE, so using a box never takes focus from the game.
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +Resize -DPIScale +MinSize96x48 +E0x08000000", "OCR Box " index)
        g.BackColor := OcrBox.Colors[index]
        g.MarginX := 0
        g.MarginY := 0
        g.SetFont("s9 bold", "Segoe UI")
        this.label := g.Add("Text", "x8 y4 w" (w - 48) " h20 BackgroundTrans c303030", "OCR Box " index)
        g.SetFont("s12 norm", "Segoe MDL2 Assets")
        this.lockCtl := g.Add("Text", "x" (w - 32) " y2 w28 h24 Center BackgroundTrans c303030 +0x100", Chr(0xE785))
        this.lockCtl.OnEvent("Click", (*) => ToggleLock(index))
        g.OnEvent("Size", (gg, mm, ww, hh) => this.OnSize(ww, hh))
        g.OnEvent("ContextMenu", (*) => ShowBoxMenu(index))
        this.gui := g
        g.Show("NoActivate x" x " y" y " w" w " h" h)
        WinSetTransparent(Integer(Cfg.Num("watch", "boxAlpha", 90, 20, 230)), "ahk_id " g.Hwnd)
    }
    OnSize(w, h) {
        try {
            this.lockCtl.Move(w - 32, 2, 28, 24)
            this.label.Move(8, 4, Max(20, w - 48), 20)
        }
    }
    Destroy() {
        try this.gui.Destroy()
    }
    ; Lock: remember where the box is, make it invisible and click-through, and start looking at what is under it.
    Lock() {
        hwnd := this.gui.Hwnd
        WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)               ; physical pixels of the virtual desktop
        if w < 24 || h < 16 {
            SetStatus("OCR Box " this.index " is too small to read - make it bigger, then lock it.")
            return false
        }
        this.rect := {x: x, y: y, w: w, h: h}
        if GameSession.Enabled && GameSession.Bound {
            if this.HasOwnProp("relativeROI")
                this.DeleteProp("relativeROI")
            if !GameSession.PrepareBox(this) {
                SetStatus("OCR regions must fit inside the selected game client.")
                return false
            }
        }
        this.locked := true
        this.gen := OcrBox.NextGen()
        WinSetTransparent(0, "ahk_id " hwnd)                          ; WS_EX_LAYERED at alpha 0: nothing is drawn ...
        WinSetExStyle("+0x20", "ahk_id " hwnd)                        ; ... and WS_EX_TRANSPARENT: every click goes to what is underneath
        this.lockCtl.Text := Chr(0xE72E)
        this.haveRef := false
        this.tracker.Reset()
        this.armAt := A_TickCount + 220                               ; let the compositor drop the tint before the first look
        Lanes[this.index].lastNorm := ""
        Log("box " this.index " locked at " x "," y " " w "x" h " (dpi " DllCall("GetDpiForWindow", "ptr", hwnd, "uint") ")")
        return true
    }
    Unlock() {
        hwnd := this.gui.Hwnd
        WinSetExStyle("-0x20", "ahk_id " hwnd)
        WinSetTransparent(Integer(Cfg.Num("watch", "boxAlpha", 90, 20, 230)), "ahk_id " hwnd)
        this.locked := false
        this.gen := OcrBox.NextGen()                                  ; anything still being read for the old position is thrown away
        this.lockCtl.Text := Chr(0xE785)
        DropPending(this.index)
        Log("box " this.index " unlocked")
    }
    ; One look (every 100 ms).  Returns "" (nothing to do), "initial" (first look after locking) or "changed" (changed, then settled).
    Look(now) {
        if !this.locked || now < this.armAt
            return ""
        if GameSession.Enabled && (!GameSession.Check() || !GameSession.Direct() || !GameSession.PrepareBox(this))
            return ""
        if !SampleSig(this.rect, this.cur) {
            this.sampleFails += 1
            if this.sampleFails <= 10
                Log("box " this.index ": the screen copy failed (Windows error " SigSize.LastError "), skipping this look (" this.sampleFails ")")
            return ""
        }
        if GameSession.Enabled && !GameSession.Check()
            return ""
        if !this.haveRef {
            DllCall("RtlMoveMemory", "ptr", this.ref, "ptr", this.cur, "uptr", SigSize.Bytes)
            DllCall("RtlMoveMemory", "ptr", this.prev, "ptr", this.cur, "uptr", SigSize.Bytes)
            this.haveRef := true
            this.tracker.Reset()
            return "initial"
        }
        dRef := SigDiff(this.ref, this.cur, SigSize.Cells)
        dPrev := SigDiff(this.prev, this.cur, SigSize.Cells)
        this.lastD := dRef
        DllCall("RtlMoveMemory", "ptr", this.prev, "ptr", this.cur, "uptr", SigSize.Bytes)
        verdict := this.tracker.Step(dRef, dPrev, now)
        if verdict = "snapshot" {
            DllCall("RtlMoveMemory", "ptr", this.ref, "ptr", this.cur, "uptr", SigSize.Bytes)
            return "changed"
        }
        if verdict = "reverted" {
            this.reverts += 1
            if this.reverts <= 10
                Log("box " this.index " moved by up to " Round(this.tracker.peak * 100, 1) "% for a moment and went back to what was already read - ignored (" this.reverts ")")
        }
        return ""
    }
}

; A full-resolution picture of a screen rectangle, as an HBITMAP the OCR library accepts.  OCR.CreateHBitmap would do, but it leaks two GDI handles
; per call (it deletes the screen DC and releases the memory DC, the wrong way round) and a long session takes thousands of snapshots.
class BoxSnap extends OCR.IBase {
    static Mem := 0
    __New(r, blit := 0) {
        oldDpi := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
        this.ptr := 0                                      ; __Delete also runs when construction fails
        if !BoxSnap.Mem
            BoxSnap.Mem := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")       ; one shared memory DC for the library's GetDIBits calls; lives as long as the script
        if !BoxSnap.Mem
            throw Error("could not create the snapshot memory DC")
        w := Max(1, r.w)
        h := Max(1, r.h)
        hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
        hdcMem := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
        hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcScreen, "int", w, "int", h, "ptr")
        old := 0
        copied := false
        try {
            if hdcScreen && hdcMem && hbm {
                old := DllCall("SelectObject", "ptr", hdcMem, "ptr", hbm, "ptr")
                copied := blit ? blit.Call(hdcMem, hdcScreen, r, w, h) : DllCall("BitBlt", "ptr", hdcMem, "int", 0, "int", 0, "int", w, "int", h, "ptr", hdcScreen, "int", r.x, "int", r.y, "uint", 0x00CC0020 | OCR.CAPTUREBLT, "int")
            }
        } finally {
            if old
                DllCall("SelectObject", "ptr", hdcMem, "ptr", old)
            if hdcMem
                DllCall("DeleteDC", "ptr", hdcMem)
            if hdcScreen
                DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
            DllCall("SetThreadDpiAwarenessContext", "ptr", oldDpi, "ptr")
        }
        if !hbm || !copied {
            if hbm
                DllCall("DeleteObject", "ptr", hbm)
            throw Error("could not copy the snapshot bitmap")
        }
        super.__New(hbm)
        this.DC := BoxSnap.Mem
    }
    __Delete() {
        if this.ptr
            DllCall("DeleteObject", "ptr", this.ptr)
    }
}

; Drag a box by its body: hand the click to Windows as a title-bar drag.  (Resizing uses the window's own sizing border.)
OnLButtonDown(wParam, lParam, msg, hwnd) {
    for b in Boxes
        if b && hwnd = b.gui.Hwnd {
            PostMessage(0xA1, 2, 0, , "ahk_id " hwnd)                 ; WM_NCLBUTTONDOWN, HTCAPTION
            return 0
        }
}

ToggleLock(n) {
    b := Boxes[n]
    if !b
        return
    if b.locked
        b.Unlock()
    else
        b.Lock()
    SyncBar()
}

ShowBoxMenu(n) {
    m := Menu()
    b := Boxes[n]
    m.Add(b && b.locked ? "Unlock" : "Lock (start reading)", (*) => ToggleLock(n))
    m.Add("Remove this box", (*) => RemoveBoxAt(n))
    m.Show()
}

AddBox() {
    slot := 0
    Loop MaxBoxes {
        if !Boxes[A_Index] {
            slot := A_Index
            break
        }
    }
    if !slot {
        SetStatus("Four boxes is the maximum.")
        return
    }
    r := NewBoxRect(slot)
    Boxes[slot] := OcrBox(slot, r.x, r.y, r.w, r.h)
    Lanes[slot].Clear()
    Lanes[slot].lastNorm := ""
    SyncBar()
    SetStatus("OCR Box " slot " added. Drag it over the text, resize it, then click its lock.")
}

RemoveLastBox() {
    Loop MaxBoxes {
        n := MaxBoxes - A_Index + 1
        if Boxes[n] {
            RemoveBoxAt(n)
            return
        }
    }
}

RemoveBoxAt(n) {
    b := Boxes[n]
    if !b
        return
    b.gen := OcrBox.NextGen()
    b.Destroy()
    Boxes[n] := 0
    Lanes[n].Clear()
    Lanes[n].lastNorm := ""
    DropPending(n)
    SyncBar()
    SetStatus("OCR Box " n " removed.")
}

DropPending(n) {
    i := Pending.Length
    while i >= 1 {
        if Pending[i].box = n
            Pending.RemoveAt(i)
        i -= 1
    }
}

; Where a new box appears: the middle of the primary monitor, each box a little lower than the last, sized for that monitor's scaling.
NewBoxRect(slot) {
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    k := DllCall("GetDpiForSystem", "uint") / 96
    w := Round(520 * k)
    h := Round(110 * k)
    x := l + (r - l - w) // 2 + (slot - 1) * Round(24 * k)
    y := t + (b - t) // 2 + (slot - 1) * Round((h + 12) * 0.5)
    x := Min(Max(x, l), Max(l, r - w))
    y := Min(Max(y, t), Max(t, b - h))
    return {x: x, y: y, w: w, h: h}
}

; ---- the control bar ---------------------------------------------------------------------------------------------------------------
BuildBar() {
    global Bar, BarCtl
    BarCtl := {chk: []}
    Bar := Gui("+AlwaysOnTop -DPIScale", "OCR Boxes")
    Bar.MarginX := 10
    Bar.MarginY := 8
    Bar.SetFont("s9", "Segoe UI")
    Bar.Add("Text", "xm w420", "Capture source")
    BarCtl.captureMode := Bar.Add("DropDownList", "xm y+4 w420", ["Any window / screen", "Game profiles (guarded)"])
    BarCtl.captureMode.Choose(GameSession.Enabled ? 2 : 1)
    BarCtl.captureMode.OnEvent("Change", CaptureModeChanged)
    if !GameSession.Enabled {
        BarCtl.capturePicker := Bar.Add("Button", "xm y+6 w420 h26", "Fit box to window / display...")
        BarCtl.capturePicker.OnEvent("Click", ShowCapturePicker)
        Bar.Add("Text", "xm y+6 w420 r2", "Or use + and drag a box over any app. Lock it, then press Play. Captures visible pixels in a fixed area.")
    }
    if GameSession.Enabled {
        labels := ["Select a game profile (reading stopped)"]
        for p in GameProfiles.Data["games"]
            labels.Push(p["name"] " — " p["validation"])
        BarCtl.profile := Bar.Add("DropDownList","w420",labels)
        BarCtl.profile.Choose(1)
        BarCtl.profile.OnEvent("Change",ObjBindMethod(GameProfiles,"Choose"))
        BarCtl.profileSource := Bar.Add("DropDownList","xm y+6 w420",["OCR Boxes (direct CPU)","Luna OCR (verified only)","Luna hook (verified only)"])
        BarCtl.profileSource.Choose(1)
        BarCtl.profileSource.OnEvent("Change",ObjBindMethod(GameProfiles,"SourceChanged"))
        BarCtl.bind := Bar.Add("Button","xm y+6 w154 h26","Bind game (3s)")
        BarCtl.bind.OnEvent("Click",ObjBindMethod(GameSession,"BindLater"))
        BarCtl.saveProfile := Bar.Add("Button","x+6 yp w156 h26","Save game profile")
        BarCtl.saveProfile.OnEvent("Click",ObjBindMethod(GameProfiles,"Save"))
        Bar.Add("Text","xm y+6 w420","Ctrl+Alt+F9 Resume in game · Ctrl+Alt+F10 Stop")
    }
    BarCtl.add := Bar.Add("Button", "xm y+8 w30 h26 Section", "+")
    BarCtl.add.OnEvent("Click", (*) => AddBox())
    BarCtl.remove := Bar.Add("Button", "x+4 ys w30 h26", Chr(0x2212))
    BarCtl.remove.OnEvent("Click", (*) => RemoveLastBox())
    BarCtl.count := Bar.Add("Text", "x+10 ys+5 w44", "0 / 4")
    Loop MaxBoxes {
        c := Bar.Add("Checkbox", "x+4 ys w36 h26 +0x1000 Disabled", A_Index)       ; BS_PUSHLIKE: a toggle button; pressed = locked
        c.OnEvent("Click", LockClick.Bind(A_Index))
        BarCtl.chk.Push(c)
    }
    Bar.Add("Text", "xs y+12 w62", "Read with")
    BarCtl.ocr := Bar.Add("DropDownList", "x+4 yp-3 w354", ["Windows OCR (built in)", "RapidOCR (Python)", "Vision model (Ollama / LM Studio)"])
    BarCtl.ocr.Choose(IndexOf(OcrKeys, Cfg.Get("ocr", "engine", "windows")))
    BarCtl.ocr.OnEvent("Change", OnOcrChange)
    if !GameSession.Enabled && !E2E {
        BarCtl.ocr.Delete()
        BarCtl.ocr.Add(["Windows OCR (CPU, all apps)","RapidOCR (CPU, all apps)"])
        BarCtl.ocr.Choose(IndexOf(OcrKeys,Cfg.Get("ocr","engine","windows")))
    }
    Bar.Add("Text", "xs y+10 w62", "Voice")
    BarCtl.eng := Bar.Add("DropDownList", "x+4 yp-3 w354", VoiceLabels)
    BarCtl.eng.Choose(IndexOf(VoiceKeys, Cfg.Get("voice", "engine", "edge")))
    BarCtl.eng.OnEvent("Change", OnEngineChange)
    BarCtl.voice := Bar.Add("DropDownList", "xs y+6 w420", [])
    BarCtl.voice.OnEvent("Change", OnVoiceChange)
    if !GameSession.Enabled
        Bar.Add("Text","xs y+5 w420 r2","Kokoro output: current Windows default (headphones when selected)")
    if !GameSession.Enabled {
        BarCtl.edgeConsent := Bar.Add("Checkbox","xs y+5 w420 r2","Allow Edge Read Aloud to briefly switch focus")
        BarCtl.edgeConsent.Value := Cfg.Get("voice","edgeBrowserFocusConsent","0") = "1"
        BarCtl.edgeConsent.OnEvent("Click",EdgeConsentChanged)
    }
    BoxVoices.AddControls()
    BarCtl.play := Bar.Add("Button", "xs y+12 w74 h28", Chr(0x25B6) " Play")
    BarCtl.play.OnEvent("Click", (*) => OnPlay())
    BarCtl.pause := Bar.Add("Button", "x+4 yp w74 h28", Chr(0x23F8) " Pause")
    BarCtl.pause.OnEvent("Click", (*) => OnPause())
    BarCtl.stop := Bar.Add("Button", "x+4 yp w74 h28", Chr(0x23F9) " Stop")
    BarCtl.stop.OnEvent("Click", (*) => OnStop())
    BarCtl.readNow := Bar.Add("Button", "x+4 yp w84 h28", "Read now")
    BarCtl.readNow.OnEvent("Click", (*) => ReadNow())
    BarCtl.luna := Bar.Add("Checkbox", "xs y+12 w170 h22", "Luna Translator text")
    BarCtl.luna.OnEvent("Click", (*) => OnLunaToggle())
    BarCtl.lunaBtn := Bar.Add("Button", "x+10 yp-4 w70 h26", "Luna...")
    BarCtl.lunaBtn.OnEvent("Click", (*) => ShowLunaMenu())
    BarCtl.status := Bar.Add("Text", "xs y+10 w420 r4", "Add a box with +, drag it over the text, then click its lock.")
    Bar.OnEvent("Close", (*) => ExitApp())
    OnMessage(0x02E0, BarDpiChanged)
    RefreshVoiceList()
    ApplyReaderTheme()
    SyncBar()
    if E2E {
        Bar.Show("NoActivate x" E2EBar.x " y" E2EBar.y " AutoSize")
        return
    }
    Bar.Show("Hide AutoSize")
    Bar.GetPos(, , &w, &h)                                      ; the bar is still hidden here: WinGetPos cannot see a hidden window ("Target window not found" - the bar then never appeared), Gui.GetPos can
    areas := []
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        areas.Push({l: l, t: t, r: r, b: b})
    }
    p := FitWorkRect(Cfg.Get("bar", "x", ""), Cfg.Get("bar", "y", ""), w, h, areas, MonitorGetPrimary())
    Bar.Show("NoActivate x" p.x " y" p.y)
    FitBarToDisplay()
}

; The OCR overlays keep physical coordinates. Only the control bar is re-fitted.
BarDpiChanged(wParam,lParam,msg,hwnd) {
    if Bar && hwnd = Bar.Hwnd
        SetTimer(FitBarToDisplay,-30)
}
FitBarToDisplay() {
    if !Bar
        return
    ; AutoSize derives client bounds from actual children after Windows adjusts
    ; the caption/borders. Do not reuse a DPI-scaled outer width as client width.
    Bar.Show("NoActivate AutoSize")
    WinGetPos(&x,&y,&w,&h,"ahk_id " Bar.Hwnd)
    areas := []
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index,&l,&t,&r,&b)
        areas.Push({l:l,t:t,r:r,b:b})
    }
    p := FitWorkRect(x,y,w,h,areas,MonitorGetPrimary())
    WinMove(p.x,p.y,,,"ahk_id " Bar.Hwnd)
}
EdgeConsentChanged(ctrl,*) {
    Cfg.Set("voice","edgeBrowserFocusConsent",ctrl.Value ? "1" : "0")
    if Cfg.Get("voice","engine","") = "browser" {
        if !ctrl.Value
            OnStop()
        SetStatus(ctrl.Value ? "Edge is enabled. Lock a box, then press Play. Choose the voice in Edge Read Aloud." : "Edge is off. Enable its focus checkbox before pressing Play, or choose Kokoro.")
    }
}
ReadingAllowed() {
    if !GameSession.Enabled && Cfg.Get("voice","engine","") = "browser" && Cfg.Get("voice","edgeBrowserFocusConsent","0") != "1" {
        SetStatus("Edge is off. Enable its focus checkbox before pressing Play, or choose Kokoro.")
        return false
    }
    return true
}

IndexOf(arr, val) {
    for i, v in arr
        if v = val
            return i
    return 1
}
; Where val is in arr, or 0 when it is not there (IndexOf answers 1 for a missing value, which suits a drop-down's default).
PositionOf(arr, val) {
    for i, v in arr
        if v = val
            return i
    return 0
}

LockClick(n, *) {
    ToggleLock(n)
}

; Counts, which toggle buttons are usable, and whether each shows locked or not.
SyncBar() {
    if !BarCtl
        return
    cnt := 0
    Loop MaxBoxes {
        b := Boxes[A_Index]
        c := BarCtl.chk[A_Index]
        if b {
            cnt += 1
            c.Enabled := true
            c.Value := b.locked ? 1 : 0
        } else {
            c.Value := 0
            c.Enabled := false
        }
    }
    BarCtl.count.Text := cnt " / " MaxBoxes
    BarCtl.add.Enabled := cnt < MaxBoxes
    BarCtl.remove.Enabled := cnt > 0
}

SetStatus(msg) {
    static last := "", at := 0
    if msg = last && A_TickCount - at < 10000
        return
    last := msg
    at := A_TickCount
    Log("status: " msg)
    if BarCtl
        try BarCtl.status.Text := msg
}

; The second drop-down: the voices of the engine in use.
RefreshVoiceList() {
    global VoiceIds
    key := Cfg.Get("voice", "engine", "edge")
    BarCtl.voice.Delete()
    VoiceIds := []
    BarCtl.voice.Enabled := true
    if key = "browser" {
        BarCtl.voice.Add(["Voice and speed: choose in Edge Read Aloud"])
        BarCtl.voice.Choose(1)
        BarCtl.voice.Enabled := false
    } else if key = "sapi" {
        if !Speakers.Has("sapi") {
            BarCtl.voice.Add(["(SAPI is not available on this PC)"])
            BarCtl.voice.Choose(1)
            BarCtl.voice.Enabled := false
            BoxVoices.Refresh()
            return
        }
        names := Speakers["sapi"].Voices()
        if !names.Length {
            BarCtl.voice.Add(["(Edge voices Ava, Brian, Ryan are not installed for SAPI)"])
            BarCtl.voice.Choose(1)
            BarCtl.voice.Enabled := false
            SetStatus("The Edge voices Ava, Brian and Ryan are not installed for SAPI (see the README); Kokoro Player is the voice until they are.")
            BoxVoices.Refresh()
            return
        }
        BarCtl.voice.Add(names)
        saved := Cfg.Get("voice", "sapiVoice", "")
        pick := 1
        for i, n in names
            if n = saved
                pick := i
        BarCtl.voice.Choose(pick)
    } else if key = "edge" {
        BarCtl.voice.Add(Speakers["edge"].Voices())
        pick := 1
        for i, v in EdgeSpeaker.Allowed
            if v.id = StrLower(Cfg.Get("voice", "edgeVoice", "ava"))
                pick := i
        BarCtl.voice.Choose(pick)
    } else if key = "kokoro" {
        items := ["Same voice as Kokoro Player"]
        VoiceIds.Push("")
        for v in Speakers["kokoro"].Voices() {
            items.Push(v.label)
            VoiceIds.Push(v.id)
        }
        BarCtl.voice.Add(items)
        saved := Cfg.Get("voice", "kokoroVoice", "")
        pick := 1
        for i, id in VoiceIds
            if id = saved
                pick := i
        BarCtl.voice.Choose(pick)
        if items.Length = 1
            SetStatus("Kokoro Player is not answering on 127.0.0.1:8787 - open it, then pick Kokoro Player again.")
    } else {
        id := Cfg.Get("eleven", "voiceId", "")
        BarCtl.voice.Add(["Voice id: " (id = "" ? "(set [eleven] voiceId in OCR Boxes.ini)" : id)])
        BarCtl.voice.Choose(1)
        BarCtl.voice.Enabled := false
    }
    BoxVoices.Refresh()
}

OnOcrChange(ctrl, *) {
    key := OcrKeys[ctrl.Value]
    if GameSession.Enabled {
        if key != "windows" && key != "rapid" {
            ctrl.Choose(IndexOf(OcrKeys,Cfg.Get("ocr","engine","windows")))
            SetStatus("Game profiles use CPU Windows OCR or RapidOCR.")
            return
        }
        GameSession.Suspend("OCR-engine-switch")
        if GameProfiles.Current
            GameProfiles.Current["engine"] := key
        Cfg.Set("ocr","engine",key)
        SetStatus("CPU OCR engine selected; the helper remains lazy until a verified OCR request.")
        return
    }
    Cfg.Set("ocr", "engine", key)
    Log("ocr engine " key)
    CancelOcrJob(true)                                        ; preserve its place in the queue for the newly selected reader
    if key = "windows" {
        SetStatus("Reading with Windows OCR.")
        return
    }
    if key = "vlm" {
        VlmSelectStep()
        return
    }
    SetStatus("Reading with RapidOCR.")
    helperState := GameSession.Enabled ? Helper.Ensure() : DesktopReader.Ensure()
    if SubStr(helperState, 1, 1) = "!"
        SetStatus(SubStr(helperState, 2))
}

; Right after the Vision reader is chosen (and again every second while the helper is still starting): find the model and start loading it, so the bar says which one reads.
VlmSelectStep() {
    if Cfg.Get("ocr", "engine", "windows") != "vlm"
        return
    helperState := Helper.Ensure()
    if SubStr(helperState, 1, 1) = "!" {
        SetStatus(SubStr(helperState, 2))
        return
    }
    if helperState != "ready" {
        SetStatus("Starting the RapidOCR helper...")
        SetTimer(VlmSelectStep, -1000)
        return
    }
    if Vlm.Detect(true) {
        SetStatus("Reading with the vision model " Vlm.Label() ".")
        if !VlmWarm.Ready()                                      ; start loading the model now, before the first snapshot ...
            SetTimer(VlmWarmWatch, -500)                         ; ... and look again until it is loaded, so the bar says when it is ready (snapshots poll it too)
    } else
        SetStatus(Vlm.NoneMessage())
}

VlmWarmWatch() {
    if Cfg.Get("ocr", "engine", "windows") != "vlm"
        return
    if !VlmWarm.Ready()
        SetTimer(VlmWarmWatch, -500)
}

CancelSpeech() {
    global Speaking, SpeechEpoch, RetryAt
    SpeechEpoch += 1
    Speaking := false
    RetryAt := 0
    try Spk.Stop()                                              ; also cancels a Start() that is waiting for the model
}

OnEngineChange(ctrl, *) {
    key := VoiceKeys[ctrl.Value]
    if GameSession.Enabled && key != "kokoro" {
        SetStatus("Game profiles use only the local CPU Kokoro Player route.")
        return
    }
    if !Speakers.Has(key) || (key = "sapi" && !SapiUsable()) {
        SetStatus(key = "sapi" ? "SAPI has none of the allowed voices (Edge Ava, Brian, Ryan) installed; Kokoro Player stays the voice." : "That voice engine is not available on this PC.")
        ctrl.Choose(IndexOf(VoiceKeys, Cfg.Get("voice", "engine", "kokoro")))
        return
    }
    CancelSpeech()
    Cfg.Set("voice", "engine", key)
    ChooseSpeaker(key)
    RefreshVoiceList()
    Log("voice engine " key)
    if key = "browser"
        SetStatus(Cfg.Get("voice","edgeBrowserFocusConsent","0") = "1" ? "Edge enabled. Its dedicated reader briefly takes focus; choose the voice in Edge." : "Edge is off. Enable its focus checkbox before pressing Play, or choose Kokoro.")
    if key = "edge" {
        helperState := Helper.Ensure()                           ; the voices run inside the RapidOCR helper: start it now, not at the first line
        SetStatus(SubStr(helperState, 1, 1) = "!" ? SubStr(helperState, 2) : "Edge voices: the spoken text goes to Microsoft's servers and needs the internet.")
    }
}

OnVoiceChange(ctrl, *) {
    if GameSession.Enabled && (!GameProfiles.Current || GameProfiles.Current["protection"] != "unprotected-confirmed") {
        CancelSpeech()
        Cfg.Set("voice","kokoroVoice","af_heart")
        Spk.voice := "af_heart"
        RefreshVoiceList()
        SetStatus("Protected/unknown profiles use explicit CPU Heart.")
        return
    }
    key := Cfg.Get("voice", "engine", "edge")
    if key = "sapi" {
        CancelSpeech()
        Cfg.Set("voice", "sapiVoice", ctrl.Text)
        Speakers["sapi"].SetVoice(ctrl.Text)
    } else if key = "edge" && ctrl.Value >= 1 && ctrl.Value <= EdgeSpeaker.Allowed.Length {
        CancelSpeech()
        id := EdgeSpeaker.Allowed[ctrl.Value].id
        Cfg.Set("voice", "edgeVoice", id)
        Speakers["edge"].SetVoice(id)
    } else if key = "kokoro" && ctrl.Value >= 1 && ctrl.Value <= VoiceIds.Length {
        CancelSpeech()
        Cfg.Set("voice", "kokoroVoice", VoiceIds[ctrl.Value])
        Spk.voice := VoiceIds[ctrl.Value]
        if GameSession.Enabled && GameProfiles.Current
            GameProfiles.Current["voice"] := Nz(Spk.voice,"af_heart")
    }
}

; ---- Play / Pause / Stop / Read now ---------------------------------------------------------------------------------------------------
OnPlay() {
    if !ReadingAllowed()
        return
    global State
    if GameSession.Enabled {
        if State = "paused" && GameSession.Check() {
            try {
                Spk.Resume()
                State := "playing"
                SetStatus("Resumed the paused game reading.")
            } catch as e {
                SetStatus(e.Message)
            }
        } else
            GameSession.Resume()
        return
    }
    if State = "paused" {
        State := "playing"
        try Spk.Resume()
        SetStatus("Playing.")
    } else if State = "stopped" {
        State := "playing"
        ReadNow()
    } else
        SetStatus("Already playing. Lock a box to read what is under it, or press Read now to read it again.")
}

OnPause() {
    global State
    if State != "playing" {
        SetStatus("Not playing.")
        return
    }
    State := "paused"
    try Spk.Pause()
    SetStatus("Paused. New text is still collected and will be read in order after Play.")
}

OnStop() {
    if GameSession.Enabled {
        GameSession.Suspend("stop")
        return
    }
    global State, QueueEpoch
    State := "stopped"
    QueueEpoch += 1
    DesktopReader.StopOcr()
    CancelSpeech()
    CancelOcrJob()
    for lane in Lanes
        lane.Clear()
    Pending.Length := 0
    for b in Boxes
        if b
            b.gen := OcrBox.NextGen()                              ; whatever is being read right now (Windows OCR, RapidOCR, vision model) is thrown away
    SetStatus("Stopped. The queue is empty. Play starts reading the locked boxes again.")
}

; Read what is under every locked box again, even if it is the text that was read a moment ago.
ReadNow() {
    if !ReadingAllowed()
        return
    if GameSession.Enabled && !GameSession.Resume()
        return
    global State
    if State = "paused"
        try Spk.Resume()                                           ; a frozen SAPI sentence would otherwise never finish
    State := "playing"
    n := 0
    for b in Boxes
        if b && b.locked {
            b.haveRef := false
            Lanes[b.index].lastNorm := ""
            n += 1
        }
    if n
        SetStatus("Reading what is in the locked " (n > 1 ? "boxes" : "box") " now.")
    else
        SetStatus("Nothing is locked yet - lock a box first.")
}

; ---- Luna Translator -----------------------------------------------------------------------------------------------------------------
OnLunaToggle() {
    if GameSession.Enabled {
        BarCtl.luna.Value := 0
        SetStatus("Choose the profile's verified source; independent Luna mixing is disabled.")
        return
    }
    global LunaState, LunaRetryAt, LunaDisconnectedAt
    LunaRetryAt := 0
    LunaDisconnectedAt := 0
    if BarCtl.luna.Value {
        if Cfg.Get("luna", "url", "") = "" {
            BarCtl.luna.Value := 0
            SetStatus("Luna Translator's text socket is not set. In Luna Translator's settings switch on its API/web service, then put the address (ws://127.0.0.1:PORT/api/ws/text/origin) in OCR Boxes.ini under [luna] url.")
            return
        }
        LunaState := "waiting"
        SetStatus("Connecting to Luna Translator...")
    } else {
        if LunaState = "on"
            try Http("POST", Helper.Url "/luna/stop", "{}", 1000)
        LunaState := "off"
        SetStatus("Luna Translator text is off.")
    }
}

ShowLunaMenu() {
    m := Menu()
    m.Add("Start Luna Translator", (*) => StartLuna(false))
    if !GameSession.Enabled
        m.Add("Start Luna Translator as administrator (some games need it)", (*) => StartLuna(true))
    m.Add("Open settings file", (*) => Run('notepad.exe "' Cfg.File '"'))
    m.Show()
}

; Luna Translator is not part of this project: point [luna] exe at the LunaTranslator.exe you extracted (not under C:\Program Files).
StartLuna(admin) {
    if GameSession.Enabled && (!GameProfiles.Current || !GameProfiles.LunaPolicyAllowed(GameProfiles.Current)) {
        SetStatus("This game/build has no approved Luna compatibility and isolation evidence.")
        return
    }
    exe := Cfg.Get("luna", "exe", "")
    if GameSession.Enabled && (admin || StrLower(exe) != StrLower("C:\AI_Workspace\tools\LunaTranslator\LunaTranslator_x64\LunaTranslator.exe")) {
        SetStatus("Use the reviewed normal Luna launcher without elevation.")
        return
    }
    if exe = "" || !FileExist(exe) {
        SetStatus("The reviewed Luna extraction build was not found. Complete its local deployment preflight.")
        return
    }
    try {
        if admin
            Run('*RunAs "' exe '"', RegExReplace(exe, "\\[^\\]+$"))
        else
            Run('"' exe '"', RegExReplace(exe, "\\[^\\]+$"))
        SetStatus("Luna started. Launch the game normally through Steam; use explicit Bind/re-arm on the same game, then Ctrl+Alt+F9 in game to Resume.")
    } catch as e
        SetStatus("Could not start Luna Translator: " e.Message)
}

PollLuna(request := 0) {
    global LunaState, LastLunaPoll, LunaRetryAt, LunaDisconnectedAt
    if GameSession.Enabled && (!GameSession.Check() || GameSession.Direct())
        return
    ticket := GameSession.Enabled ? GameSession.Ticket() : 0
    if LunaState = "off" || A_TickCount - LastLunaPoll < 400 || A_TickCount < LunaRetryAt
        return
    LastLunaPoll := A_TickCount
    send := request ? request : Http
    wantedUrl := Cfg.Get("luna", "url", "")
    if LunaState = "waiting" {
        helperState := Helper.Ensure()
        if helperState = "starting"
            return
        if helperState != "ready" {
            SetStatus(SubStr(helperState, 2))
            LunaRetryAt := A_TickCount + 2000
            return
        }
        r := send.Call("POST", Helper.Url "/luna/connect", '{"url":' JsonStr(wantedUrl) (ticket ? ',"session":' GameJson.Dump(ticket) : "") '}', 3000)
        if GameSession.Enabled && !GameSession.Check(ticket)
            return
        if r.status != 200 {
            SetStatus("Luna Translator: " Nz(JsonField(r.text, "error"), "the helper did not accept the address"))
            if r.status = 0 || r.status >= 500 {
                Helper.Invalidate()
                LunaRetryAt := A_TickCount + 2000
            } else {
                if BarCtl
                    BarCtl.luna.Value := 0
                LunaState := "off"
            }
            return
        }
        LunaState := "on"
        LunaDisconnectedAt := A_TickCount
        SetStatus("Waiting for Luna Translator to connect...")
        return
    }
    r := ticket ? send.Call("POST", Helper.Url "/luna/poll", '{"session":' GameJson.Dump(ticket) '}', 1500)
                : send.Call("GET", Helper.Url "/luna/poll", "", 1500)
    if GameSession.Enabled && !GameSession.Check(ticket)
        return
    if GameSession.Enabled && r.status = 409 {
        GameSession.Suspend("Luna-session-rejected")
        return
    }
    if r.status != 200 || !JsonTrue(r.text, "ok") {
        Helper.Invalidate()
        LunaState := "waiting"
        LunaRetryAt := A_TickCount + 2000
        SetStatus("Luna Translator's helper disconnected. Reconnecting...")
        return
    }
    configured := JsonField(r.text, "url")
    hasUrl := RegExMatch(r.text, '"url"\s*:') > 0
    if (hasUrl && configured != wantedUrl) || (!hasUrl && !JsonTrue(r.text, "connected") && JsonField(r.text, "error") = "" && A_TickCount - LunaDisconnectedAt > 10000) {
        LunaState := "waiting"                                  ; a restarted helper has lost its feed; reconnect it once
        LunaRetryAt := A_TickCount + 2000
        SetStatus("Restoring Luna Translator's connection...")
        return
    }
    if JsonTrue(r.text, "connected") {
        LunaDisconnectedAt := 0
        SetStatus("Listening to Luna Translator. Lines it extracts are read in order with the boxes.")
    } else {
        if !LunaDisconnectedAt
            LunaDisconnectedAt := A_TickCount
        SetStatus("Luna Translator disconnected. Retrying: " Nz(JsonField(r.text, "error"), "waiting for the text socket"))
    }
    ; The helper handles socket retries with backoff. Do not keep closing a configured feed.
    if GameSession.Enabled {
        data := GameJson.Load(r.text)
        for event in data.Get("items", []) {
            if !GameSession.AcceptLuna(event,ticket) {
                GameSession.Drops["luna"] += 1
                GameSession.Suspend("Luna-source-identity-changed")
                return
            }
            Lanes[MaxBoxes+1].Offer(CleanText(event["text"]),A_TickCount,ticket)
        }
    } else {
        for line in ParseStringArray(r.text, "items")
            if State != "stopped"
                Lanes[MaxBoxes + 1].Offer(CleanText(line), A_TickCount)
    }
}

; ---- the 100 ms tick: look -> snapshot -> read -> speak ---------------------------------------------------------------------------------
Tick() {
    global TickBusy
    if TickBusy
        return
    TickBusy := true
    try {
        PumpOcr()
        PollLuna()
        PumpSpeech()
    } catch as e {
        Log("tick error: " e.Message " (" e.What ", line " e.Line ")")
    } finally {
        TickBusy := false
    }
}

; The looks at the boxes have their own timer so that they carry on (while Windows OCR is waiting on the system, for example).
SampleTick() {
    global SampleBusy
    if SampleBusy
        return
    SampleBusy := true
    try {
        SampleBoxes()
    } catch as e {
        Log("look error: " e.Message " (" e.What ", line " e.Line ")")
    } finally {
        SampleBusy := false
    }
}

SampleBoxes() {
    if EdgeBrowserSpeaker.Configuring
        return ; the native reader must never feed its own setup window into OCR
    if GameSession.Enabled && (!GameSession.Check() || !GameSession.Direct())
        return
    if E2E
        E2EGuard()
    global SampleMs, SampleCount, LastReport
    if State = "stopped"
        return
    t0 := A_TickCount
    looked := 0
    for b in Boxes {
        if !b || !b.locked
            continue
        looked += 1
        why := b.Look(t0)
        if why != ""
            TakeSnapshot(b, why " d=" Round(b.lastD * 100, 2) "%")
    }
    if looked {
        SampleMs += A_TickCount - t0
        SampleCount += 1
        if A_TickCount - LastReport > 60000 {
            Log("looks: " looked " locked, avg " Round(SampleMs / SampleCount, 1) " ms per round, queue " Pending.Length " snapshots, " Rdr.Total() " lines")
            SampleMs := 0
            SampleCount := 0
            LastReport := A_TickCount
        }
    }
}

; A full-resolution picture of the box, taken the moment the text settled.  The reader gets to it when it can; the text may be gone by then.
TakeSnapshot(b, why, capture := 0) {
    if GameSession.Enabled && (!GameSession.Check() || !GameSession.Direct()) {
        GameSession.Drops["capture"] += 1
        return
    }
    ticket := GameSession.Enabled ? GameSession.Ticket() : 0
    if E2E
        E2EGuard()
    r := b.rect
    try {
        hbm := capture ? capture.Call(r) : BoxSnap(r)
    } catch as e {
        b.haveRef := false
        b.tracker.Reset()
        Log("snapshot failed: " e.Message)
        return
    }
    if GameSession.Enabled && !GameSession.Check(ticket) {
        GameSession.Drops["capture"] += 1
        return
    }
    ; The look that decided on this snapshot saw b.cur.  If the copy differs a lot from it, the screen changed in between (a flash, a frame of a fade): reading it
    ; could lose the text for good, because the tracker already counts what it saw as read.  Look again instead - the next look makes a fresh reference and snapshot.
    snapSig := Buffer(SigSize.Bytes, 0)
    if b.snapRetries < 2 && SigOfBitmap(hbm.ptr, r.w, r.h, snapSig) {
        dSnap := SigDiff(b.cur, snapSig, SigSize.Cells)
        if dSnap >= b.tracker.diffFrac / 2 {
            b.snapRetries += 1
            b.haveRef := false
            Log("box " b.index ": the snapshot differs from the look that asked for it by " Round(dSnap * 100, 1) "% - taking it again (" b.snapRetries ")")
            return
        }
    }
    b.snapRetries := 0
    if E2E && EnvGet("OCRBOXES_E2E_SNAPS") != ""                         ; end-to-end diagnostics only: keep every snapshot of the TEST windows as a picture
        try SaveBmp(hbm.ptr, EnvGet("OCRBOXES_E2E_SNAPS") "\box" b.index "-" Format("{:06}", A_TickCount - E2EStarted) "-" RegExReplace(why, "\W.*$") ".bmp")
    Pending.Push({box: b.index, gen: b.gen, hbm: hbm, rect: r, at: A_TickCount, why: why, tries: 0, session: ticket})
    WarmSpeech()
    while Pending.Length > PendingCap {
        dropped := DropForOverflow()
        GameSession.Drops["snapshot_overflow"] += 1
        Log("the reader is behind: a snapshot of box " dropped " was dropped")
        SetStatus("The reader cannot keep up with this much changing text - a snapshot was dropped.")
    }
}

; Queue full: drop from the busiest box, and never its oldest unread snapshot (that one holds the line it is waiting to read) - its second-oldest instead.
; Dropping the oldest of the whole queue lost the first lines of every box while a vision model was loading (owner's PC, 2026-10-10).
DropForOverflow() {
    counts := Map()
    busiest := 0
    for item in Pending {
        counts[item.box] := (counts.Has(item.box) ? counts[item.box] : 0) + 1
        if !busiest || counts[item.box] > counts[busiest]
            busiest := item.box
    }
    seen := 0
    for i, item in Pending
        if item.box = busiest && ++seen = 2 {
            Pending.RemoveAt(i)
            return busiest
        }
    first := Pending.RemoveAt(1)
    return first.box
}

; Which model reads the pictures: [vlm] model in OCR Boxes.ini when it is set, otherwise the first vision-capable model the helper finds in Ollama or LM Studio
; (a text-only model such as qwen3 cannot read a picture).  Nothing is pulled, loaded or started by the search itself.
class Vlm {
    ; AutoHotkey treats names case-insensitively and a class cannot hold a field and a method with the same name, so the found values are fFoo and the methods are Foo().
    static request := 0                  ; tests: callable(method, url, body, timeoutMs)
    static fBackend := "", fModel := "", fUrl := "", fLabel := "", notes := "", askedAt := 0
    static Configured() => Cfg.Get("vlm", "model", "") != ""
    static Backend() => Vlm.Configured() ? Cfg.Get("vlm", "backend", "ollama") : Vlm.fBackend
    static Model() => Vlm.Configured() ? Cfg.Get("vlm", "model", "") : Vlm.fModel
    static Url() => Vlm.Configured() ? Cfg.Get("vlm", "url", "http://127.0.0.1:11434") : Vlm.fUrl
    static Label() => Vlm.Configured() ? Cfg.Get("vlm", "model", "") : Vlm.fLabel
    static Reset() {
        Vlm.fBackend := "", Vlm.fModel := "", Vlm.fUrl := "", Vlm.fLabel := "", Vlm.notes := "", Vlm.askedAt := 0
    }
    ; True when a model is usable.  Asks the helper (a second or two) unless the INI names one or one was found already; after a miss it waits 20 s before asking again,
    ; unless force is set (the owner just chose the Vision reader).
    static Detect(force := false) {
        if Vlm.Configured() || (Vlm.fModel != "" && !force)
            return true
        if !force && Vlm.askedAt && A_TickCount - Vlm.askedAt < 20000
            return false
        Vlm.askedAt := A_TickCount
        r := (Vlm.request ? Vlm.request : Http).Call("POST", Helper.Url "/vlm/models", "{}", 15000)
        if r.status = 404 {
            Vlm.notes := "The running RapidOCR helper is older than the vision model search. Close it (OCR Boxes starts its own)."
            return false
        }
        if r.status != 200 {
            Vlm.notes := Nz(JsonField(r.text, "error"), "the helper did not answer (" Nz(r.text, "HTTP " r.status) ")")
            return false
        }
        Vlm.notes := JsonField(r.text, "notes")
        found := JsonField(r.text, "pickedModel")
        if found = "" {
            Vlm.fModel := ""
            return false
        }
        Vlm.fBackend := JsonField(r.text, "pickedBackend"), Vlm.fModel := found, Vlm.fUrl := JsonField(r.text, "pickedUrl"), Vlm.fLabel := JsonField(r.text, "pickedLabel")
        Log("vision model found: " Vlm.fLabel)
        return true
    }
    static NoneMessage() => "Vision model: none found. Ollama or LM Studio needs a model that can read a picture (for example: ollama pull qwen2.5vl:7b), or name one in OCR Boxes.ini ([vlm] model)." (Vlm.notes != "" ? " (" Vlm.notes ")" : "")
}

; A vision model loads into memory on its first request (14.9 s for qwen2.5vl:7b on the owner's PC); every snapshot taken meanwhile waits in the queue.
; So the model is asked to load once, without an image, before the first snapshot is sent - the queue keeps its order while it loads.
class VlmWarm {
    static key := ""          ; backend|model|url that is loaded (or that answered the warm-up either way)
    static req := 0
    static reqKey := ""
    static startedAt := 0
    static post := (url, body, wait) => AsyncPost(url, body, wait)
    ; True when snapshots may go to the model now; false while a warm-up is running.
    static Ready() {
        Vlm.Detect()
        backend := Vlm.Backend(), model := Vlm.Model(), url := Vlm.Url()
        key := backend "|" model "|" url
        if VlmWarm.key = key || model = ""
            return true
        if VlmWarm.req && VlmWarm.reqKey != key {
            try VlmWarm.req.Abort()
            VlmWarm.req := 0
        }
        if !VlmWarm.req {
            VlmWarm.reqKey := key
            VlmWarm.startedAt := A_TickCount
            VlmWarm.req := VlmWarm.post.Call(Helper.Url "/vlm/warm", '{"backend":' JsonStr(backend) ',"model":' JsonStr(model) ',"url":' JsonStr(url) ',"timeout":120}', 130000)
            SetStatus("Loading the vision model " Vlm.Label() "...")
            Log("vlm warm-up started")
            return false
        }
        if !VlmWarm.req.Poll()
            return false
        r := VlmWarm.req
        VlmWarm.req := 0
        VlmWarm.key := key                                      ; failed or not: the snapshots go on, and a real error shows on the first one
        Log("vlm warm-up " (r.error = "" && r.status = 200 ? "done ms=" (A_TickCount - VlmWarm.startedAt) : "failed: " Nz(r.error, "HTTP " r.status)))
        if r.error = "" && r.status = 200
            SetStatus("Reading with the vision model " Vlm.Label() ".")
        return true
    }
    static Reset() {
        if VlmWarm.req
            try VlmWarm.req.Abort()
        VlmWarm.req := 0, VlmWarm.key := "", VlmWarm.reqKey := ""
    }
}

StaleSnapshot(item) {
    if GameSession.Enabled && (!item.HasOwnProp("session") || !GameSession.Check(item.session))
        return true
    b := Boxes[item.box]
    return !b || !b.locked || item.gen != b.gen
}

PumpOcr() {
    if GameSession.Enabled && (!GameSession.Check() || !GameSession.Direct())
        return
    global Job
    if Job && (Cfg.Get("ocr", "engine", "windows") != Job.eng || StaleSnapshot(Job.item))
        CancelOcrJob(true)
    if Job {
        if !Job.req.Poll()
            return
        FinishJob()
    }
    while Pending.Length && StaleSnapshot(Pending[1])
        Pending.RemoveAt(1)
    if !Pending.Length
        return
    eng := Cfg.Get("ocr", "engine", "windows")
    if eng = "windows" {
        item := Pending.RemoveAt(1)
        t0 := A_TickCount
        text := ""
        try
            text := OcrWindows(item)
        catch as e
            Log("windows ocr failed: " e.Message)
        Log("ocr windows box=" item.box " why=" item.why " ms=" (A_TickCount - t0) " waited=" (t0 - item.at) " chars=" StrLen(text))
        AcceptText(item, text, eng)
        return
    }
    helperState := (!GameSession.Enabled && eng = "rapid") ? DesktopReader.Ensure() : Helper.Ensure()
    if helperState = "starting" {
        SetStatus("Starting the RapidOCR helper...")
        return
    }
    if helperState != "ready" {
        SetStatus(SubStr(helperState, 2))
        return
    }
    if eng = "vlm" && !Vlm.Detect() {
        SetStatus(Vlm.NoneMessage())                              ; the snapshots wait in the queue; the search is repeated every 20 s
        return
    }
    if eng = "vlm" && !VlmWarm.Ready()
        return
    item := Pending.RemoveAt(1)
    path := SnapshotFiles.NewPath(item.box)
    try {
        SaveBmp(item.hbm.ptr, path)
    } catch as e {
        SnapshotFiles.Delete(path)
        if !StaleSnapshot(item) {
            Boxes[item.box].haveRef := false
            Boxes[item.box].tracker.Reset()
        }
        Log("could not save the snapshot: " e.Message)
        return
    }
    if eng = "rapid" {
        url := (GameSession.Enabled ? Helper.Url : DesktopReader.Url) "/ocr"
        body := GameSession.Enabled ? '{"image":' JsonStr(path) ',"session":' GameJson.Dump(item.session) '}' : DesktopReader.Body('"image":' JsonStr(path) ',"epoch":' QueueEpoch)
        wait := 25000
    } else {
        url := Helper.Url "/vlm"
        body := '{"image":' JsonStr(path) ',"backend":' JsonStr(Vlm.Backend()) ',"model":' JsonStr(Vlm.Model()) ',"url":' JsonStr(Vlm.Url()) ',"timeout":60}'
        wait := 70000
    }
    Job := {item: item, req: AsyncPost(url, body, wait), path: path, eng: eng, t0: A_TickCount}
}

CancelOcrJob(requeue := false) {
    global Job
    if !Job
        return
    j := Job
    Job := 0
    try j.req.Abort()
    SnapshotFiles.Delete(j.path)
    if requeue && !StaleSnapshot(j.item)
        Pending.InsertAt(1, j.item)
    else
        j.item.hbm := ""
}

FinishJob() {
    global Job
    j := Job
    Job := 0
    SnapshotFiles.Delete(j.path)
    if GameSession.Enabled && j.req.status = 409 {
        GameSession.Suspend("helper-session-rejected")
        return
    }
    if j.req.error != "" || j.req.status != 200 {
        msg := Nz(j.req.error, Nz(JsonField(j.req.text, "error"), "HTTP " j.req.status))
        Log("ocr " j.eng " failed: " msg)
        who := (j.eng = "vlm") ? "Vision model: " : "RapidOCR: "
        SetStatus(who . msg)
        j.item.tries += 1
        retryable := j.req.error != "" || j.req.status = 0 || j.req.status >= 500
        if retryable
            Helper.Invalidate()                                  ; the next retry must verify the helper, not reuse cached readiness
        if retryable && j.item.tries < 2 && !StaleSnapshot(j.item)
            Pending.InsertAt(1, j.item)                            ; once more, in its place at the front of the queue
        return
    }
    text := CleanText(JsonField(j.req.text, "text"))
    Log("ocr " j.eng " box=" j.item.box " why=" j.item.why " ms=" (A_TickCount - j.t0) " waited=" (j.t0 - j.item.at) " chars=" StrLen(text))
    AcceptText(j.item, text, j.eng)
}

; Windows OCR on the snapshot: scale 2 first, then the harder passes (grayscale / inverted / bigger) until one reads well.
; Two passes with nothing readable mean the box is blank (a line that just vanished), so the rest are skipped.
OcrWindows(item) {
    best := ""
    bestScore := 0
    tried := 0
    good := Cfg.Num("ocr", "goodScore", 4, 1, 100)
    otherLanguage := Cfg.Get("ocr", "lang", "") != ""
    for p in Passes {
        sc := Max(1, Min(p.s, 9000 // Max(item.rect.w, item.rect.h)))
        tr := {scale: sc, grayscale: p.g, invertcolors: p.i}
        try {
            res := (OcrLang != "") ? OCR.FromBitmap(item.hbm, OcrLang, tr) : OCR.FromBitmap(item.hbm, , tr)
            txt := CleanText(LinesToText(res.Lines))
        } catch as e {
            Log("ocr pass " A_Index " failed: " e.Message)
            continue
        }
        tried += 1
        s := Score(txt)
        if s = 0 && otherLanguage && RegExMatch(txt, "\p{L}{2}")
            s := 0.6                                               ; Score only understands Latin letters
        if (s > 0 && bestScore = 0) || s > bestScore * 1.15 {
            best := txt
            bestScore := s
        }
        if bestScore >= good
            break
        if tried >= 2 && bestScore = 0
            break
    }
    return bestScore >= 0.5 ? best : ""
}

; An OCR result enters the box's queue here (a blank result is how the box learns that its text has gone).
AcceptText(item, text, eng) {
    if GameSession.Enabled && (!item.HasOwnProp("session") || !GameSession.Check(item.session)) {
        GameSession.Drops["text"] += 1
        return
    }
    b := Boxes[item.box]
    if !b || !b.locked || item.gen != b.gen
        return
    if text != "" && !Readable(text, eng)
        text := ""
    res := Lanes[item.box].Offer(text, A_TickCount, GameSession.Enabled ? item.session : 0)
    Log("box " item.box " -> " res)
}

Readable(text, eng) {
    if StrLen(text) < 2
        return false
    if eng = "windows" {
        if Score(text) >= 0.5                                      ; "Wait!" and "Yes." are lines too (they score 0.8 and 0.75)
            return true
        return (Cfg.Get("ocr", "lang", "") != "" && RegExMatch(text, "\p{L}{2}")) ? true : false
    }
    return RegExMatch(text, "[\p{L}\p{N}]") ? true : false
}

; One sentence at a time, in the order the Reader says; the next one starts when the voice reports the last one over.
PumpSpeech() {
    PumpSpeechCore()
    BoxState.Set((Speaking && State != "paused") ? "speaking" : "idle")      ; for the avatars in the app; no text is ever written
}

PumpSpeechCore() {
    if GameSession.Enabled && !GameSession.Check()
        return
    global Speaking, SpeakingSince, RetryAt, State
    epoch := SpeechEpoch
    startedQueueEpoch := QueueEpoch
    speaker := Spk
    if Speaking {
        if speaker.Busy() || epoch != SpeechEpoch
            return
        Speaking := false
        Log("spoken in " (A_TickCount - SpeakingSince) " ms")
        if Spk.LastError != ""
            SetStatus(Spk.LastError)
    }
    if State != "playing" || A_TickCount < RetryAt
        return
    turn := Rdr.last
    next := Rdr.Next()
    if !next
        return
    try {
        if GameSession.Enabled {
            if !next.item.HasOwnProp("session") || !GameSession.Check(next.item.session) {
                GameSession.Drops["speech"] += 1
                return
            }
            ticket := next.item.session
            speaker.SessionCheck := (*) => GameSession.Check(ticket)
            speaker.voice := GameProfiles.Current["protection"] = "unprotected-confirmed" ? GameProfiles.Current["voice"] : "af_heart"
        }
        BoxVoices.Apply(PositionOf(Lanes,next.lane),speaker)
        speaker.Start(next.item.text)
        if epoch != SpeechEpoch || startedQueueEpoch != QueueEpoch || State = "stopped" {
            if startedQueueEpoch = QueueEpoch && State != "stopped" {
                next.lane.PutBack(next.item)
                Rdr.last := turn
            }
            return
        }
        if E2E && E2ESpoken.Length
            E2ESpoken[E2ESpoken.Length].lane := next.lane.name
        Speaking := true
        SpeakingSince := A_TickCount
        Log("speak " next.lane.name " engine=" Spk.Name " chars=" StrLen(next.item.text) " left=" Rdr.Total())
    } catch as e {
        if startedQueueEpoch = QueueEpoch && State != "stopped" {
            next.lane.PutBack(next.item)
            Rdr.last := turn
            RetryAt := epoch = SpeechEpoch ? A_TickCount + 3000 : 0
            if epoch = SpeechEpoch
                SetStatus(e.Message)
            if (speaker is EdgeBrowserSpeaker || e is BoxVoiceError) && epoch = SpeechEpoch {
                speaker.Stop()
                State := "paused"
                SetStatus(e.Message " Press Play to retry.")
            }
        }
    }
}

; ---- self test:  AutoHotkey64.exe "OCR Boxes.ahk" --selftest result.txt ----------------------------------------------------------------
T(name, ok, detail := "") {
    global Results
    line := (ok ? "PASS " : "FAIL ") name (detail != "" ? "  [" detail "]" : "") "`n"
    Results .= line
    if SelfTest && A_Args.Length >= 2
        try FileAppend(line, A_Args[2] ".progress", "UTF-8")          ; a run that is killed by a watchdog still shows how far it got
}

OnTestError(e, mode) {
    T("unexpected exception", false, e.Message " line " e.Line)
    out := A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\selftest.txt"
    try FileAppend(Results, out, "UTF-8")
    ExitApp(2)
}

RunSelfTest() {
    global Results
    out := A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\selftest.txt"
    PrepareTestStorage(out)
    try {
        SelfTestLogic()
    } catch as e {
        T("self test ran to the end", false, e.Message " line " e.Line)
    }
    try FileDelete(out)
    FileAppend(Results, out, "UTF-8")
    ExitApp()
}

SelfTestLogic() {
    ; -- text comparison
    T("NormText", NormText("  Hello,   WORLD!! It's 5 o'clock. ") = "hello world it s 5 o clock")
    T("WordSim same words", WordSim("the gate is locked", "the gate is locked") = 1.0)
    T("WordSim one misread word", WordSim("the gate is locked now", "the gate is locked") >= 0.8)
    T("WordSim different", WordSim("open the door", "close the window") < 0.5)
    T("SkipWords", SkipWords("The gate is locked, and barred.", 4) = "and barred")
    T("Score: one short word is a line", Score("Wait!") >= 0.5 && Score("Yes.") >= 0.5 && Score("No.") >= 0.5)
    T("Score: symbols are not", Score("~ ^ | ``") < 0.5 && Score("") = 0)
    ; -- lanes: strict FIFO and the judgement of a new OCR result
    ln := Lane("t")
    T("lane first line queued", ln.Offer("The gate is locked.") = "queued" && ln.Count = 1)
    T("lane same text again", ln.Offer("The gate is locked,") = "same" && ln.Count = 1)
    T("lane blank forgets", ln.Offer("") = "blank" && ln.lastNorm = "")
    T("lane same words after a blank are new", ln.Offer("The gate is locked.") = "queued" && ln.Count = 2)
    ln2 := Lane("typed")
    ln2.Offer("The gate is")
    T("typed line replaces the unread short one", ln2.Offer("The gate is locked and barred") = "extended" && ln2.Count = 1 && ln2.items[1].text = "The gate is locked and barred")
    ln2.Pop()
    T("typed line, short version already read: only the tail", ln2.Offer("The gate is locked and barred by order of the king") = "tail" && ln2.Count = 1 && ln2.items[1].text = "by order of the king")
    ln3 := Lane("one-extra-word")
    ln3.Offer("who goes there my friend and why")
    ln3.Pop()
    T("one extra word on a long line is not swallowed", ln3.Offer("who goes there my friend and why now") = "tail" && ln3.items[1].text = "now")
    ln4 := Lane("fifo")
    for line in ["first line here", "second line there", "third line again"] {
        ln4.Offer(line)
        ln4.Offer("")
    }
    T("lane is first in first out", ln4.Pop().text = "first line here" && ln4.Pop().text = "second line there" && ln4.Pop().text = "third line again")
    ln5 := Lane("mem", 200, 1000)
    ln5.Offer("Yes.", 0)
    T("remember window: repeat inside it is ignored", ln5.Offer("Yes.", 500) = "same")
    T("remember window: repeat after it is new", ln5.Offer("Yes.", 5000) = "queued" && ln5.Count = 2)
    ln6 := Lane("cap", 3)
    for line in ["one a", "two b", "three c", "four d", "five e"] {
        ln6.Offer(line)
        ln6.Offer("")
    }
    T("lane cap drops the oldest", ln6.Count = 3 && ln6.dropped = 2 && ln6.items[1].text = "three c")
    ; -- reader order
    la := Lane("a")
    lb := Lane("b")
    lc := Lane("c")
    rd := Reader([la, lb, lc], "box")
    for line in ["a one", "a two", "a three"] {
        la.Offer(line)
        la.Offer("")
    }
    lc.Offer("c one")
    order := ""
    while n := rd.Next()
        order .= n.item.text "|"
    T("reader: box 1, box 3, box 1, box 1 (empty boxes skipped)", order = "a one|c one|a two|a three|", order)
    ld := Lane("d")
    le := Lane("e")
    rt := Reader([ld, le], "time")
    le.Offer("e first")
    ld.Offer("d second")
    ld.Offer("")
    le.Offer("")
    le.Offer("e third")
    order := ""
    while n := rt.Next()
        order .= n.item.text "|"
    T("reader order=time follows arrival", order = "e first|d second|e third|", order)
    ; -- frame comparison
    cells := 100
    x := Buffer(cells * 4, 0x80)
    y := Buffer(cells * 4, 0x80)
    T("SigDiff identical", SigDiff(x, y, cells) = 0)
    NumPut("uint", 0xFFFFFFFF, y, 40)
    T("SigDiff one bright cell", Abs(SigDiff(x, y, cells) - 0.01) < 0.0001)
    NumPut("uint", 0x80808080, y, 40)
    NumPut("uint", 0x90909090, y, 44)
    T("SigDiff ignores small shifts", SigDiff(x, y, cells) = 0)
    ; -- change tracker
    ct := ChangeTracker(0.015, 0.0006, 2, 2500)
    seq := ""
    for step in [[0, 0], [0.30, 0.30], [0.30, 0.0], [0.30, 0.0]]
        seq .= ct.Step(step[1], step[2], A_Index * 100) ? "S" : "."
    T("tracker: change, then calm for two looks -> one snapshot", seq = "...S", seq)
    ct := ChangeTracker(0.015, 0.0006, 2, 2500)
    seq := ""
    for step in [[0.2, 0.2], [0.3, 0.1], [0.3, 0.1], [0.3, 0.1], [0.3, 0.0], [0.3, 0.0]]
        seq .= ct.Step(step[1], step[2], A_Index * 100) ? "S" : "."
    T("tracker: text still being typed is not snapshotted early", seq = ".....S", seq)
    ct := ChangeTracker(0.015, 0.0006, 2, 1000)
    seq := ""
    Loop 15
        seq .= ct.Step(0.4, 0.4, A_Index * 100) ? "S" : "."
    T("tracker: never settling -> snapshot after maxSettle", InStr(seq, "S") = 11, seq)
    ct := ChangeTracker(0.015, 0.0006, 2, 2500)
    seq := ""
    Loop 10
        seq .= ct.Step(0.004, 0.004, A_Index * 100) ? "S" : "."
    T("tracker: noise below the threshold never triggers", seq = "..........", seq)
    ; a flash that is gone again (dRef back to 0) must not be read as a new text; the one after it that really differs still is
    ct := ChangeTracker(0.015, 0.0006, 2, 2500)
    seq := ""
    for step in [[0.2, 0.2], [0, 0.2], [0, 0], [0, 0], [0.3, 0.3], [0.3, 0], [0.3, 0]]
        seq .= (v := ct.Step(step[1], step[2], A_Index * 100)) = "snapshot" ? "S" : (v = "reverted" ? "r" : ".")
    T("tracker: a flash that goes back to the last picture is ignored, a real change after it is still read", seq = "...r..S", seq)
    ; -- JSON snippets
    text := "Caf" Chr(0xE9) " " Chr(0x201C) "quoted" Chr(0x201D) " back\slash `"q`"`nline2`ttab"
    T("json roundtrip", JsonUnstr(SubStr(JsonStr(text), 2, -1)) == text)
    T("json unicode escape", JsonUnstr("Caf\u00e9 \ud83d\ude00") == "Caf" Chr(0xE9) " " Chr(0x1F600))
    arr := ParseStringArray('{"ok": true, "items": ["one", "two \"q\" \u00e9", "line\nbreak"], "connected": true}', "items")
    T("string array", arr.Length = 3 && arr[1] = "one" && arr[2] = "two `"q`" " Chr(0xE9) && arr[3] = "line`nbreak", arr.Length)
    T("empty string array", ParseStringArray('{"items": [], "x": 1}', "items").Length = 0)
    T("json field", JsonField('{"ok":true,"text":"Hi \"there\""}', "text") = 'Hi "there"')
    T("json true", JsonTrue('{"speaking": true}', "speaking") && !JsonTrue('{"speaking": false}', "speaking"))
    SelfTestRegressions()
    ; -- the pieces that touch Windows
    hb := 0
    try {
        hdc := DllCall("GetDC", "ptr", 0, "ptr")
        hb := DllCall("CreateCompatibleBitmap", "ptr", hdc, "int", 20, "int", 10, "ptr")
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
        tmp := Logger.Dir "\selftest-" DllCall("GetCurrentProcessId") ".bmp"
        dims := SaveBmp(hb, tmp)
        f := FileOpen(tmp, "r")
        sig := f.ReadUShort()
        f.Seek(2)
        total := f.ReadUInt()
        f.Close()
        T("bmp writer", sig = 0x4D42 && dims.w = 20 && dims.h = 10 && total = 54 + 20 * 4 * 10 && FileGetSize(tmp) = total, "size " FileGetSize(tmp))
        FileDelete(tmp)
    } catch as ex {
        T("bmp writer", false, ex.Message)
    }
    try FileDelete(tmp)
    if hb
        DllCall("DeleteObject", "ptr", hb)
    try {
        sapiTest := SapiSpeaker()                                   ; the real code path, not a copy of it
        voiceNames := sapiTest.Voices()
        bad := ""
        for nm in voiceNames
            if !SapiSpeaker.IsAllowed(nm) || SapiSpeaker.IsExcluded(nm)
                bad .= nm "; "
        T("SAPI lists only the three allowed Edge voices", bad = "", voiceNames.Length " of the 3 installed" (bad != "" ? "; NOT ALLOWED: " bad : ""))
        bad := ""
        for nm in ["Microsoft Ava Multilingual Online (Natural) - English (United States)", "Microsoft Brian Multilingual Online (Natural) - English (United States)", "Microsoft Ryan Online (Natural) - English (United Kingdom)"]
            if !SapiSpeaker.IsAllowed(nm)
                bad .= nm "; "
        for nm in ["Microsoft David Desktop - English (United States)", "Microsoft Hazel Desktop - English (Great Britain)", "Microsoft George Desktop - English (United Kingdom)", "Microsoft Zira Desktop - English (United States)", "Microsoft Susan Desktop - English (United Kingdom)", "Microsoft David - English (United States)", "Microsoft Hazel - English (United Kingdom)"]
            if SapiSpeaker.IsAllowed(nm) || !SapiSpeaker.IsExcluded(nm)
                bad .= nm "; "
        for nm in ["Microsoft Ava Online (Natural) - English (United States)", "Microsoft Jenny Online (Natural) - English (United States)", "Microsoft Mark - English (United States)", "Microsoft Ryan - English (United Kingdom)"]
            if SapiSpeaker.IsAllowed(nm)
                bad .= nm "; "
        T("the voice rule: Ava / Brian / Ryan pass; David, Hazel, George, Zira, Susan and other voices are refused", bad = "", bad)
        refused := !sapiTest.SetVoice("Microsoft David Desktop - English (United States)") && !sapiTest.SetVoice("Microsoft Zira Desktop - English (United States)") && sapiTest.chosen = ""
        T("a saved setting that names an excluded voice is ignored", refused)
        threw := false
        try
            sapiTest.Start("This must never be spoken.")
        catch
            threw := true
        T("SAPI refuses to speak (nothing is said) when no allowed voice is chosen", threw && sapiTest.chosen = "")
    } catch as ex {
        T("SAPI voice rule", false, ex.Message)
    }
    try {
        langs := StrReplace(Trim(OCR.GetAvailableLanguages(), "`n"), "`n", ",")
        T("OCR languages", langs != "", langs)
    } catch as ex {
        T("OCR languages", false, ex.Message)
    }
    tStart := A_TickCount
    portOneListening := PortListening(1)
    h := Http("GET", "http://127.0.0.1:1/", "", 1500)
    T("a closed local port is answered at once (Windows itself needs about 2 s)", !portOneListening && h.status = 0 && A_TickCount - tStart < 400, "port 1 listening=" portOneListening ", " (A_TickCount - tStart) " ms")
    T("(info) PortListening sees the Windows RPC port 135", true, PortListening(135) ? "yes" : "no")
    h := Http("GET", "http://127.0.0.1:8787/health", "", 1500)
    T("(info) Kokoro Player reachable", true, "status " h.status)
    h := Http("GET", Helper.Url "/health", "", 1500)
    T("(info) RapidOCR helper reachable", true, "status " h.status)
    MonitorGet(1, &mLeft, &mTop, &mRight, &mBottom)               ; (a variable named t would hide the T() function in this whole function)
    T("(info) monitors", true, MonitorGetCount() " found; primary " MonitorGetPrimary() "; first " mLeft "," mTop " " (mRight - mLeft) "x" (mBottom - mTop) "; dpi " DllCall("GetDpiForSystem", "uint"))
}



; Regression probes are silent: transports, voices and failed capture are stand-ins.
class RegressionCaptureContext {
    Verify(*) {
        this.v2 := DllCall("AreDpiAwarenessContextsEqual", "ptr", DllCall("GetThreadDpiAwarenessContext", "ptr"), "ptr", -4, "int")
        return false
    }
}
class RegressionVoiceApi {
    Resume() {
    }
    Speak(text, flags) {
        this.text := text
        this.flags := flags
    }
}
class RegressionRequest {
    __New(status := 0, text := "", error := "") {
        this.status := status
        this.text := text
        this.error := error
        this.aborted := 0
        this.ready := false
    }
    Poll() => this.ready
    Abort() {
        this.aborted += 1
    }
}
RegressionWarm(calls, url, body) {
    r := RegressionRequest(200, '{"ok":true,"warmed":true}')
    calls.Push({url: url, body: body, req: r})
    return r
}
class RegressionKokoro {
    __New(action) {
        this.action := action
        this.calls := 0
        this.stops := 0
        this.lastBody := ""
    }
    Send(method, url, body, timeout) {
        if InStr(url, "/stop") {
            this.stops += 1
            return {status: 200, text: "{}"}
        }
        this.calls += 1
        this.lastBody := body
        if this.calls = 1 {
            SetTimer(this.action, -50)
            return {status: 503, text: "{}"}
        }
        return {status: 200, text: "{}"}
    }
}
class RegressionHelper {
    __New(healthy := true) {
        this.healthy := healthy
        this.calls := []
    }
    Send(method, url, body, timeout) {
        this.calls.Push(method " " url)
        return {status: this.healthy ? 200 : 503, text: '{"ok":true,"engine":"legacy"}'}
    }
    Listening(*) => true
}
class RegressionEdge {
    __New() {
        this.posts := []
        this.stops := 0
        this.warms := 0
        this.statusText := '{"ok":true,"speaking":true,"error":"","fetchMs":-1,"id":1}'
        this.startReply := {status: 200, text: '{"ok":true,"id":1}'}
    }
    Send(method, url, body, timeout) {
        if InStr(url, "/tts/edge/stop") {
            this.stops += 1
            return {status: 200, text: '{"ok":true}'}
        }
        if InStr(url, "/tts/edge/status")
            return {status: 200, text: this.statusText}
        if InStr(url, "/tts/edge/warm") {
            this.warms += 1
            return {status: 200, text: '{"ok":true,"started":true}'}
        }
        this.posts.Push({url: url, body: body})
        return this.startReply
    }
}
class RegressionVlmFinder {
    __New() {
        this.calls := []
        this.reply := {status: 200, text: '{"ok":true,"found":true,"pickedBackend":"ollama","pickedModel":"qwen2.5vl:7b","pickedUrl":"http://127.0.0.1:11434","pickedLabel":"qwen2.5vl:7b (Ollama)","notes":"","count":2,"models":[{"backend":"ollama","model":"qwen2.5vl:7b"},{"backend":"lmstudio","model":"qwen/qwen2.5-vl-7b"}]}'}
    }
    Send(method, url, body, timeout) {
        this.calls.Push({method: method, url: url, body: body})
        return this.reply
    }
}
class RegressionLuna {
    __New() {
        this.reply := {status: 200, text: '{"ok":true,"items":[],"connected":false,"error":"","url":""}'}
        this.connects := 0
    }
    Send(method, url, body, timeout) {
        if InStr(url, "/connect") {
            this.connects += 1
            return {status: 200, text: '{"ok":true}'}
        }
        return this.reply
    }
}
RegressionCaptureFails(*) {
    throw Error("intentional failed snapshot")
}
RegressionStopThenPlay(*) {
    OnStop()
    OnPlay()
}
SelfTestRegressions() {
    global Boxes, Lanes, Rdr, Spk, Speakers, Pending, Job, State, Speaking, RetryAt, VoiceIds, VoiceKeys, VoiceLabels
    global SpeechEpoch, QueueEpoch, LunaState, LastLunaPoll, LunaRetryAt, LunaDisconnectedAt
    original := {boxes: Boxes, lanes: Lanes, rdr: Rdr, spk: Spk, speakers: Speakers, pending: Pending, job: Job,
                 state: State, speaking: Speaking, retryAt: RetryAt, ids: VoiceIds}
    helperCache := {known: Helper.known, answer: Helper.lastAnswer, at: Helper.checkedAt, start: Helper.startedAt,
                    url: Helper.Url, request: Helper.request, listening: Helper.portListening}
    try {
        ; The first '<' in OCR input must never invoke SAPI's XML parser.
        sapi := SapiSpeaker()
        fakeApi := RegressionVoiceApi()
        sapi.v := fakeApi
        sapi.chosen := "regression-test voice"                       ; the fake COM object stands in for an allowed voice (Start refuses without one)
        sapi.Start('<spell> & unfinished')
        T("SAPI speaks OCR as literal asynchronous text", fakeApi.flags = 17 && fakeApi.text = '<spell> & unfinished')

        Helper.Url := "http://127.0.0.1:8799"
        Helper.known := false
        Helper.startedAt := 0
        transport := RegressionHelper()
        Helper.request := ObjBindMethod(transport, "Send")
        Helper.portListening := ObjBindMethod(transport, "Listening")
        answer := Helper.EnsureNow()
        T("an incompatible helper is never stopped or replaced", SubStr(answer, 1, 1) = "!" && transport.calls.Length = 2
            && transport.calls[1] = "GET http://127.0.0.1:8799/health" && transport.calls[2] = "GET http://127.0.0.1:8799/tts/status" && !Helper.startedAt)
        transport.healthy := false
        answer := Helper.EnsureNow()
        T("an occupied unhealthy helper port is not taken over", SubStr(answer, 1, 1) = "!" && transport.calls.Length = 3 && !Helper.startedAt)
        Helper.Url := "http://example.com:8799"
        answer := Helper.EnsureNow()
        T("invalid helper destinations are rejected before HTTP", SubStr(answer, 1, 1) = "!" && transport.calls.Length = 3)
        Helper.Url := helperCache.url
        Helper.request := helperCache.request
        Helper.portListening := helperCache.listening

        ; Edge natural voices (online, through the helper): only Ava / Brian / Ryan, and the classic Windows voices can never be chosen.
        Helper.Url := "http://127.0.0.1:8799"
        Helper.lastAnswer := "ready"
        Helper.checkedAt := A_TickCount
        edgeTransport := RegressionEdge()
        edge := EdgeSpeaker(ObjBindMethod(edgeTransport, "Send"))
        probe := Gui("-Caption +ToolWindow")
        probe.Add("Text", "w200 h40", "hidden bar probe")
        probe.Show("Hide AutoSize")
        probe.GetPos(, , &probeW, &probeH)
        probe.Destroy()
        T("a hidden window can be measured before it is placed (the bar's first show)", probeW > 50 && probeH > 20, probeW "x" probeH)
        T("OCR Boxes' own helper port is not the Game Voice Reader helper's 8799", Helper.DefaultUrl != "http://127.0.0.1:8799" && RegExMatch(Helper.DefaultUrl, "^http://127\.0\.0\.1:\d+$"), Helper.DefaultUrl)
        helperScript := Helper.ScriptPath()
        T("the helper that sits next to this script is found, with its Edge voice module", FileExist(helperScript) && FileExist(RegExReplace(helperScript, "[^\\]+$") "extras.py") && FileExist(RegExReplace(helperScript, "[^\\]+$") "edge_tts.py"), helperScript)
        T("the voice engine list has one label per engine and Edge (online) comes first", VoiceLabels.Length = VoiceKeys.Length && VoiceKeys[1] = "edge" && InStr(VoiceLabels[1], "Edge natural voices (online)") && PositionOf(VoiceKeys, "kokoro") > 0 && InStr(VoiceLabels[PositionOf(VoiceKeys, "kokoro")], "Kokoro"))
        names := edge.Voices()
        T("Edge lists exactly Ava, Brian and Ryan", names.Length = 3 && InStr(names[1], "Ava Multilingual") && InStr(names[2], "Brian Multilingual") && InStr(names[3], "Ryan Online"))
        refused := true
        for name in ["david", "Microsoft David Desktop", "hazel", "george", "zira", "susan", "jenny", "en-US-JennyNeural", ""] {
            if edge.SetVoice(name)
                refused := false
        }
        T("Edge refuses David, Hazel, George, Zira, Susan and every other voice", refused && edge.voice = "ava")
        T("Edge accepts Ryan in any letter case", edge.SetVoice("Ryan") && edge.voice = "ryan")
        edge.voice := "david"                                         ; a corrupted setting must not reach the helper
        threw := false
        try {
            edge.Start("Hello")
        } catch {
            threw := true
        }
        T("Edge will not speak with a voice that is not one of the three", threw && edgeTransport.posts.Length = 0)
        edge.SetVoice("brian")
        edge.rate := 10
        edge.Start("It's a <test> & done")
        T("Edge sends the text, voice id and rate to the helper", edgeTransport.posts.Length = 1 && InStr(edgeTransport.posts[1].url, "/tts/edge") && JsonField(edgeTransport.posts[1].body, "voice") = "brian" && InStr(edgeTransport.posts[1].body, '"rate":10') && InStr(edgeTransport.posts[1].body, "<test>"))
        edge.startTick := A_TickCount - 500
        T("Edge is busy while the helper says it is speaking", edge.Busy())
        edgeTransport.statusText := '{"ok":true,"speaking":false,"error":"could not reach the Edge voice service (OSError)","fetchMs":-1,"id":1}'
        T("Edge reports a finished line and the service error", !edge.Busy() && InStr(edge.LastError, "could not reach"))
        edge.Stop()
        T("Edge stop is sent to the helper", edgeTransport.stops = 1 && !edge.Busy())
        edge.Warm()
        T("Edge warm-up asks the helper to open the connection ahead of the line", edgeTransport.warms = 1 && edgeTransport.posts.Length = 1)
        edgeTransport.startReply := {status: 404, text: ""}
        threw := false
        try {
            edge.Start("Hello again")
        } catch {
            threw := true
        }
        T("a helper without the Edge routes gives a clear message", threw && InStr(edge.LastError, "older"))
        Helper.Url := helperCache.url

        areas := [{l: -1920, t: -119, r: 0, b: 1021}, {l: 0, t: 0, r: 1920, b: 1020}]
        p := FitWorkRect(-1800, -80, 400, 400, areas, 2)
        T("bar retains a valid negative-coordinate display", p.x = -1800 && p.y = -80)
        p := FitWorkRect(4000, 2000, 400, 400, areas, 2)
        T("bar returns to the current primary after a display is removed", p.x = 1520 && p.y = 620)
        p := FitWorkRect("invalid", "", 400, 400, areas, 1)
        T("invalid saved bar position falls back safely", p.x >= -1920 && p.x + 400 <= 0 && p.y >= -119 && p.y + 400 <= 1021)
        p := FitWorkRect(-30, -10, 400, 400, areas, 2)
        T("bar crossing a monitor edge remains wholly visible", p.x = 0 && p.y = 0)

        box := {index: 1, gen: 1, locked: true, haveRef: true, snapRetries: 0,
                rect: {x: 0, y: 0, w: 20, h: 10}, tracker: ChangeTracker()}
        box.tracker.Step(0.3, 0.3, A_TickCount)
        Pending := []
        TakeSnapshot(box, "test", RegressionCaptureFails)
        T("failed snapshot is retried on the next look", !box.haveRef && box.tracker.state = "idle" && Pending.Length = 0)

        probe := RegressionCaptureContext()
        oldContext := DllCall("SetThreadDpiAwarenessContext", "ptr", -2, "ptr")
        failedBuffer := Buffer(SigSize.Bytes, 0x80)
        copied := SampleSig(box.rect, failedBuffer, ObjBindMethod(probe, "Verify"))
        restored := DllCall("AreDpiAwarenessContextsEqual", "ptr", DllCall("GetThreadDpiAwarenessContext", "ptr"), "ptr", -2, "int")
        T("signature capture uses physical pixels and preserves a failed buffer", !copied && probe.v2 && restored && NumGet(failedBuffer, 0, "uint") = 0x80808080)
        try BoxSnap(box.rect, ObjBindMethod(probe, "Verify"))
        restored := DllCall("AreDpiAwarenessContextsEqual", "ptr", DllCall("GetThreadDpiAwarenessContext", "ptr"), "ptr", -2, "int")
        T("full snapshot restores the caller's DPI context after failure", probe.v2 && restored)
        DllCall("SetThreadDpiAwarenessContext", "ptr", oldContext, "ptr")

        ; The injected blit fails without reading any screen pixels.
        try BoxSnap(box.rect, (*) => false)
        process := DllCall("GetCurrentProcess", "ptr")
        before := DllCall("GetGuiResources", "ptr", process, "uint", 0, "uint")
        rejected := 0
        Loop 100 {
            try BoxSnap(box.rect, (*) => false)
            catch
                rejected += 1
        }
        after := DllCall("GetGuiResources", "ptr", process, "uint", 0, "uint")
        T("failed BitBlt is rejected without a GDI handle leak", rejected = 100 && after <= before + 1, before " -> " after)

        Boxes := [box, 0, 0, 0]
        Lanes := [Lane("OCR Box 1"), Lane("OCR Box 2"), Lane("OCR Box 3"), Lane("OCR Box 4"), Lane("Luna Translator")]
        Rdr := Reader(Lanes)
        req := RegressionRequest()
        path := SnapshotFiles.NewPath(1)
        FileAppend("synthetic snapshot", path)
        item := {box: 1, gen: box.gen, hbm: {ptr: 0}, rect: box.rect, at: A_TickCount, why: "test", tries: 0}
        Job := {item: item, req: req, path: path, eng: "vlm", t0: A_TickCount}
        Pending := [{box: 1, gen: box.gen, marker: "later"}]
        OnOcrChange({Value: 1})
        T("switching to Windows aborts a hung model and retains FIFO", !Job && req.aborted = 1 && !FileExist(path) && Pending.Length = 2 && Pending[1] = item && Pending[2].marker = "later")
        Pending := []

        Helper.known := true
        Helper.lastAnswer := "ready"
        Helper.checkedAt := A_TickCount
        Helper.startedAt := A_TickCount
        path := SnapshotFiles.NewPath(1)
        FileAppend("synthetic snapshot", path)
        req := RegressionRequest(503, '{"error":"test service restart"}')
        Job := {item: item, req: req, path: path, eng: "rapid", t0: A_TickCount}
        FinishJob()
        T("failed helper invalidates cached readiness before its FIFO retry", Helper.lastAnswer = "" && !Helper.known && !Helper.startedAt && Pending.Length = 1 && Pending[1] = item && item.tries = 1 && !FileExist(path))
        Pending := []

        Pending := []
        Loop 20
            Pending.Push({box: 1, gen: box.gen, n: A_Index})
        Loop 5
            Pending.Push({box: 2, gen: box.gen, n: 100 + A_Index})
        dropped := DropForOverflow()
        T("a full queue drops the busiest box's second-oldest, never an oldest unread line", dropped = 1 && Pending.Length = 24 && Pending[1].n = 1 && Pending[2].n = 3 && Pending[20].n = 101)
        Pending := []

        warmCalls := []
        VlmWarm.Reset()
        VlmWarm.post := (url, body, wait) => RegressionWarm(warmCalls, url, body)
        savedModel := Cfg.Get("vlm", "model", "")
        Cfg.Set("vlm", "model", "selftest-vision")
        first := VlmWarm.Ready()
        second := VlmWarm.Ready()
        T("the vision model is warmed once before snapshots are sent", !first && !second && warmCalls.Length = 1 && InStr(warmCalls[1].url, "/vlm/warm") && JsonField(warmCalls[1].body, "model") = "selftest-vision")
        warmCalls[1].req.ready := true
        T("snapshots go on once the warm-up answers, without a second warm-up", VlmWarm.Ready() && VlmWarm.Ready() && warmCalls.Length = 1)
        Cfg.Set("vlm", "model", "selftest-other")
        T("a different model is warmed again", !VlmWarm.Ready() && warmCalls.Length = 2 && JsonField(warmCalls[2].body, "model") = "selftest-other")
        VlmWarm.Reset()
        Cfg.Set("vlm", "model", savedModel)

        ; the Vision reader finds a model by itself (the owner's first try failed with "choose a vision model first": OCR Boxes.ini had no [vlm] model)
        savedBackend := Cfg.Get("vlm", "backend", "ollama")
        Cfg.Set("vlm", "model", "")
        Vlm.Reset()
        finder := RegressionVlmFinder()
        Vlm.request := ObjBindMethod(finder, "Send")
        T("with no model in the INI the helper is asked which models can read a picture", Vlm.Detect(true) && finder.calls.Length = 1 && finder.calls[1].method = "POST" && InStr(finder.calls[1].url, "/vlm/models"))
        T("the model it found is the one used, with its own service address", Vlm.Model() = "qwen2.5vl:7b" && Vlm.Backend() = "ollama" && Vlm.Url() = "http://127.0.0.1:11434" && Vlm.Label() = "qwen2.5vl:7b (Ollama)")
        T("a model that was found is not searched for again", Vlm.Detect() && Vlm.Detect() && finder.calls.Length = 1)
        Cfg.Set("vlm", "model", "owner-model")
        Cfg.Set("vlm", "backend", "lmstudio")
        T("a model named in OCR Boxes.ini always wins and nothing is asked", Vlm.Model() = "owner-model" && Vlm.Backend() = "lmstudio" && Vlm.Detect(true) && finder.calls.Length = 1)
        Cfg.Set("vlm", "model", "")
        Cfg.Set("vlm", "backend", savedBackend)
        Vlm.Reset()
        finder.reply := {status: 200, text: '{"ok":true,"found":false,"pickedModel":"","notes":"Ollama: could not reach 127.0.0.1:11434: URLError; LM Studio: could not reach 127.0.0.1:1234: URLError","count":0,"models":[]}'}
        T("with no vision model anywhere the status says what to do", !Vlm.Detect(true) && Vlm.Model() = "" && InStr(Vlm.NoneMessage(), "ollama pull") && InStr(Vlm.NoneMessage(), "[vlm] model") && InStr(Vlm.NoneMessage(), "LM Studio"))
        T("after a miss the search waits before asking again, unless the reader was just chosen", !Vlm.Detect() && finder.calls.Length = 2 && !Vlm.Detect(true) && finder.calls.Length = 3)
        finder.reply := {status: 404, text: '{"ok":false}'}
        T("an older helper without the search is reported", !Vlm.Detect(true) && InStr(Vlm.NoneMessage(), "older"))
        finder.reply := {status: 200, text: '{"ok":true,"found":true,"pickedBackend":"lmstudio","pickedModel":"qwen/qwen2.5-vl-7b","pickedUrl":"http://127.0.0.1:1234","pickedLabel":"qwen/qwen2.5-vl-7b (LM Studio)","notes":"","count":1,"models":[]}'}
        T("a model installed later is found by the next search", Vlm.Detect(true) && Vlm.Backend() = "lmstudio" && Vlm.Url() = "http://127.0.0.1:1234")
        ; choosing the Vision reader: the status names the model, or says there is none
        savedOcr := Cfg.Get("ocr", "engine", "windows")
        helperSaved := {url: Helper.Url, answer: Helper.lastAnswer, at: Helper.checkedAt}
        Helper.Url := "http://127.0.0.1:8799"
        Helper.lastAnswer := "ready"
        Helper.checkedAt := A_TickCount
        Cfg.Set("ocr", "engine", "vlm")
        Vlm.Reset()
        finder.calls := []
        finder.reply := {status: 200, text: '{"ok":true,"found":true,"pickedBackend":"ollama","pickedModel":"qwen2.5vl:7b","pickedUrl":"http://127.0.0.1:11434","pickedLabel":"qwen2.5vl:7b (Ollama)","notes":"","count":1,"models":[]}'}
        VlmWarm.Reset()
        VlmWarm.post := (url, body, wait) => RegressionWarm(warmCalls, url, body)
        warmCalls := []
        VlmSelectStep()
        T("choosing the Vision reader finds the model and starts loading it", finder.calls.Length = 1 && warmCalls.Length = 1 && JsonField(warmCalls[1].body, "model") = "qwen2.5vl:7b" && JsonField(warmCalls[1].body, "backend") = "ollama")
        SetTimer(VlmWarmWatch, 0)                                    ; the real watcher would call VlmWarmWatch; the test calls it by hand
        T("the warm-up is not finished yet", !VlmWarm.Ready() && VlmWarm.key = "")
        warmCalls[1].req.ready := true
        VlmWarmWatch()
        T("the watcher notices the finished warm-up, with no snapshot needed", VlmWarm.key = "ollama|qwen2.5vl:7b|http://127.0.0.1:11434")
        SetTimer(VlmWarmWatch, 0)
        VlmWarm.Reset()
        Vlm.Reset()
        finder.reply := {status: 200, text: '{"ok":true,"found":false,"pickedModel":"","notes":"","count":0,"models":[]}'}
        warmCalls := []
        VlmSelectStep()
        T("choosing the Vision reader with no model starts nothing", warmCalls.Length = 0 && !Vlm.Detect())
        Cfg.Set("ocr", "engine", savedOcr)
        Helper.Url := helperSaved.url
        Helper.lastAnswer := helperSaved.answer
        Helper.checkedAt := helperSaved.at
        VlmWarm.Reset()
        Vlm.request := 0
        Vlm.Reset()
        Cfg.Set("vlm", "model", savedModel)

        ; the voice list only offers engines that can speak here
        savedKeys := VoiceKeys.Clone(), savedLabels := VoiceLabels.Clone()
        savedVoiceId := Cfg.Get("eleven", "voiceId", "")
        savedKeyEnv := EnvGet("ELEVENLABS_API_KEY")
        Cfg.Set("eleven", "voiceId", "")
        T("ElevenLabs without a voice id is reported as not set up", InStr(ElevenProblem(), "voice id"))
        Cfg.Set("eleven", "voiceId", "voice-123")
        EnvSet("ELEVENLABS_API_KEY", "")
        keyFileThere := FileExist(A_AppData "\PixelCompanions\elevenlabs.key") != ""
        T("ElevenLabs without an API key is reported as not set up", keyFileThere || InStr(ElevenProblem(), "API key"))
        EnvSet("ELEVENLABS_API_KEY", "test-key-never-sent")
        T("ElevenLabs with a voice id and a key is ready", ElevenProblem() = "")
        TrimVoiceLists()
        T("ElevenLabs is listed only when it is set up", PositionOf(VoiceKeys, "eleven") > 0 && VoiceLabels.Length = VoiceKeys.Length)
        VoiceKeys := savedKeys.Clone(), VoiceLabels := savedLabels.Clone()
        Cfg.Set("eleven", "voiceId", "")
        TrimVoiceLists()
        T("ElevenLabs is left out while it is not set up", PositionOf(VoiceKeys, "eleven") = 0 && PositionOf(VoiceKeys, "edge") = 1 && PositionOf(VoiceKeys, "kokoro") > 0 && VoiceLabels.Length = VoiceKeys.Length)
        T("the SAPI adapter entry is listed only when one of the three voices is installed for SAPI", (PositionOf(VoiceKeys, "sapi") > 0) = SapiUsable())
        VoiceKeys := savedKeys, VoiceLabels := savedLabels
        Cfg.Set("eleven", "voiceId", savedVoiceId)
        EnvSet("ELEVENLABS_API_KEY", savedKeyEnv)

        path := SnapshotFiles.NewPath(1)
        FileAppend("synthetic snapshot", path)
        req := RegressionRequest()
        Job := {item: item, req: req, path: path, eng: "rapid", t0: A_TickCount}
        CancelOcrJob()
        T("shutdown cancellation deletes the owned in-flight bitmap", !Job && req.aborted = 1 && !FileExist(path) && item.hbm = "")
        live := SnapshotFiles.Dir "\ocrbox-v2-" DllCall("GetCurrentProcessId") "-999-box1.bmp"
        dead := SnapshotFiles.Dir "\ocrbox-v2-999999999-999-box1.bmp"
        other := SnapshotFiles.Dir "\ocrbox-legacy.bmp"
        for f in [live, dead, other]
            FileAppend("synthetic", f)
        SnapshotFiles.ReapOld()
        T("stale cleanup retains live-process and legacy files", FileExist(live) && !FileExist(dead) && FileExist(other))
        FileDelete(live)
        FileDelete(other)

        ; Interrupt Start while its first HTTP 503 is sleeping; no audio or real HTTP.
        for action in [OnStop, RegressionStopThenPlay] {
            transport := RegressionKokoro(action)
            Spk := KokoroSpeaker(ObjBindMethod(transport, "Send"))
            State := "playing"
            Speaking := false
            RetryAt := 0
            Lanes[1].Clear()
            Lanes[1].lastNorm := ""
            Lanes[1].Offer("A stopped line must stay stopped.")
            PumpSpeechCore()
            T("Stop during a loading voice cannot retry or resurrect text (" action.Name ")", transport.calls = 1 && transport.stops = 1 && !Speaking && Rdr.Total() = 0)
        }
        VoiceIds := ["new-voice"]
        Cfg.Set("voice", "engine", "kokoro")
        transport := RegressionKokoro((*) => OnVoiceChange({Value: 1}))
        Spk := KokoroSpeaker(ObjBindMethod(transport, "Send"))
        Spk.voice := "old-voice"
        Speakers := Map("kokoro", Spk)
        State := "playing"
        Speaking := false
        RetryAt := 0
        Lanes[1].Clear()
        Lanes[1].Offer("Continue with the new voice.")
        PumpSpeechCore()
        T("voice switch cancels loading and returns its line to FIFO", transport.calls = 1 && transport.stops = 1 && !Speaking && Rdr.Total() = 1 && Spk.voice = "new-voice")
        PumpSpeechCore()
        T("the retried line uses the new voice without stale retries", transport.calls = 2 && JsonField(transport.lastBody, "voice") = "new-voice" && Speaking && Rdr.Total() = 0)

        Cfg.Set("luna", "url", "ws://127.0.0.1:2333/test")
        transport := RegressionLuna()
        send := ObjBindMethod(transport, "Send")
        LunaState := "on"
        LastLunaPoll := 0
        LunaRetryAt := 0
        PollLuna(send)
        T("a restarted helper's empty Luna feed requests reconnection", LunaState = "waiting")
        Helper.lastAnswer := "ready"
        Helper.checkedAt := A_TickCount
        LastLunaPoll := 0
        LunaRetryAt := 0
        PollLuna(send)
        T("Luna restores its subscription once after helper restart", transport.connects = 1 && LunaState = "on")
        transport.reply := {status: 200, text: '{"ok":true,"items":[],"connected":false,"error":"socket closed","url":"ws://127.0.0.1:2333/test"}'}
        LastLunaPoll := 0
        PollLuna(send)
        T("Luna socket backoff is not reset by repeated polling", transport.connects = 1 && LunaState = "on")
        transport.reply := {status: 0, text: ""}
        LastLunaPoll := 0
        PollLuna(send)
        T("failed Luna poll invalidates the helper and schedules recovery", LunaState = "waiting" && Helper.lastAnswer = "" && LunaRetryAt > A_TickCount)
    } finally {
        CancelOcrJob()
        VlmWarm.Reset()
        VlmWarm.post := (url, body, wait) => AsyncPost(url, body, wait)
        SnapshotFiles.Cleanup()
        Boxes := original.boxes, Lanes := original.lanes, Rdr := original.rdr, Spk := original.spk
        Speakers := original.speakers, Pending := original.pending, Job := original.job
        State := original.state, Speaking := original.speaking, RetryAt := original.retryAt, VoiceIds := original.ids
        Helper.known := helperCache.known, Helper.lastAnswer := helperCache.answer
        Helper.checkedAt := helperCache.at, Helper.startedAt := helperCache.start
        Helper.Url := helperCache.url, Helper.request := helperCache.request, Helper.portListening := helperCache.listening
        LunaState := "off"
    }
}

; Test paths and captures belong to the isolated run, never the user's settings/state.
PrepareTestStorage(out) {
    SplitPath(out, , &dir)
    if dir = ""
        throw Error("Tests require an absolute result path.")
    DirCreate(dir)
    Cfg.File := dir "\OCR Boxes.ini"
    Logger.Dir := dir "\logs"
    DirCreate(Logger.Dir)
    Logger.File := Logger.Dir "\boxes.log"
    BoxState.Dir := dir "\state"
    BoxState.Path := BoxState.Dir "\state.txt"
    SnapshotFiles.Dir := dir "\pending-snaps"
    DirCreate(SnapshotFiles.Dir)
}

; Fail closed if a fixture disappears, moves, or its display becomes primary.
E2EGuard() {
    global E2EFailure
    for i, r in E2EBoxes {
        safe := false
        Loop MonitorGetCount() {
            if A_Index = MonitorGetPrimary()
                continue
            MonitorGet(A_Index, &l, &t, &rr, &bb)
            if r.x >= l && r.y >= t && r.x + r.w <= rr && r.y + r.h <= bb
                safe := true
        }
        hwnd := E2EFixtures[i]
        if safe && DllCall("IsWindowVisible", "ptr", hwnd) {
            try {
                WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
                safe := r.x >= x && r.y >= y && r.x + r.w <= x + w && r.y + r.h <= y + h
            } catch
                safe := false
        } else
            safe := false
        if !safe {
            E2EFailure := "fixture " i " is no longer wholly on a non-primary display"
            E2EFinish()
        }
    }
}

; ---- end-to-end run:  AutoHotkey64.exe "OCR Boxes.ahk" --e2e out.txt windows|rapid|vlm seconds barX barY  x y w h [x y w h ...] ----------------
; Builds the real bar and boxes (at the given physical-pixel rectangles), locks them, reads what is under them with the chosen engine, and writes what WOULD
; have been spoken (in order, with the time) plus each box's window styles to out.txt.  A silent stand-in voice is used and a temporary settings file, so
; nothing is spoken and the owner's settings are untouched.  Nobody has to click anything: only use rectangles that cover a test window of your own.
class NullSpeaker {
    Name := "silent test voice"
    LastError := ""
    __New() {
        this.t := 0
    }
    Start(text) {
        this.t := A_TickCount
        E2ESpoken.Push({ms: A_TickCount - E2EStarted, lane: "?", text: text})
    }
    Busy() => A_TickCount - this.t < 700
    Stop() {
        this.t := 0
    }
    Pause() {
    }
    Resume() {
    }
}

E2EPrepare() {
    global E2EOut, E2EEngine, E2ESeconds, E2EBar
    E2EOut := A_Args[2]
    E2EEngine := A_Args[3]
    E2ESeconds := Integer(A_Args[4])
    E2EBar := {x: Integer(A_Args[5]), y: Integer(A_Args[6])}
    i := 7
    while i + 3 <= A_Args.Length && E2EBoxes.Length < 4 {
        E2EBoxes.Push({x: Integer(A_Args[i]), y: Integer(A_Args[i + 1]), w: Integer(A_Args[i + 2]), h: Integer(A_Args[i + 3])})
        i += 4
    }
    PrepareTestStorage(E2EOut)
    helperUrl := EnvGet("OCRBOXES_E2E_HELPER_URL")
    if !RegExMatch(helperUrl, "^http://127\.0\.0\.1:\d+$")
        throw Error("E2E requires its own loopback helper URL.")
    Helper.Url := helperUrl
    for hwnd in StrSplit(EnvGet("OCRBOXES_E2E_FIXTURES"), ",")
        if hwnd != ""
            E2EFixtures.Push(Integer(hwnd))
    if E2EFixtures.Length != E2EBoxes.Length
        throw Error("E2E requires one owned fixture window per box.")
}

E2ERun() {
    global Spk, E2EStarted
    E2EStarted := A_TickCount
    Cfg.Set("ocr", "engine", E2EEngine)
    vlmModel := EnvGet("OCRBOXES_E2E_VLM_MODEL")                      ; the temporary settings file has no model; run-e2e.ps1 -VlmModel passes one
    if vlmModel != ""
        Cfg.Set("vlm", "model", vlmModel)
    vlmUrl := EnvGet("OCRBOXES_E2E_VLM_URL")
    if vlmUrl != ""
        Cfg.Set("vlm", "url", vlmUrl)
    vlmBackend := EnvGet("OCRBOXES_E2E_VLM_BACKEND")                  ; ollama | lmstudio (run-e2e.ps1 -VlmBackend)
    if vlmBackend = "ollama" || vlmBackend = "lmstudio"
        Cfg.Set("vlm", "backend", vlmBackend)
    Spk := NullSpeaker()
    for i, r in E2EBoxes {
        Boxes[i] := OcrBox(i, r.x, r.y, r.w, r.h)
        Lanes[i].Clear()
    }
    SyncBar()
    SetTimer(E2ELock, -500)
    SetTimer(E2EFinish, -(E2ESeconds * 1000))
}

E2ELock() {
    E2EGuard()
    for b in Boxes
        if b
            b.Lock()
    OnPlay() ; the owned-fixture run explicitly starts; normal startup remains stopped
    SyncBar()
    FileAppend("ready", E2EOut ".ready", "UTF-8")
}

E2EFinish() {
    out := "E2E engine=" E2EEngine " seconds=" E2ESeconds " start_tick=" E2EStarted "`n"
    if E2EFailure != ""
        out .= "FAIL safety guard: " E2EFailure "`n"
    for b in Boxes
        if b {
            ex := WinGetExStyle("ahk_id " b.gui.Hwnd)
            wr := b.rect ? (b.rect.x "," b.rect.y " " b.rect.w "x" b.rect.h) : "(not locked)"
            out .= "box " b.index " rect " wr " dpi=" DllCall("GetDpiForWindow", "ptr", b.gui.Hwnd, "uint") " exstyle=0x" Format("{:X}", ex) " layered=" ((ex & 0x80000) ? 1 : 0) " clickthrough=" ((ex & 0x20) ? 1 : 0) " noactivate=" ((ex & 0x08000000) ? 1 : 0) " locked=" (b.locked ? 1 : 0) "`n"
        }
    for it in E2ESpoken
        out .= "spoken +" it.ms "ms [" it.lane "] " it.text "`n"
    try FileDelete(E2EOut)
    FileAppend(out, E2EOut, "UTF-8")
    ExitApp()
}

; ---- go (last, so that every class above is defined before Main runs) ------------------------------------------------------------------
if SelfTest {
    GameSession.Enabled := false
    OnError(OnTestError)
    SetTimer(RunSelfTest, -50)
} else if E2E {
    E2EPrepare()
    Main()
    SetTimer(E2ERun, -1500)
} else
    Main()




