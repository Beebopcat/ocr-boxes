#Requires AutoHotkey v2.0
; General screen-area capture is independent of the optional curated game profiles.
CaptureModeChanged(ctrl, *) {
    wanted := ctrl.Value = 2 ? "games" : "general"
    if wanted = (GameSession.Enabled ? "games" : "general")
        return
    OnStop() ; invalidate OCR, speech and the current game-helper session before changing modes
    try {
        IniWrite(wanted, Cfg.File, "capture", "mode")
        if IniRead(Cfg.File, "capture", "mode", "") != wanted
            throw Error("The capture mode was not saved.")
    } catch as e {
        ctrl.Choose(GameSession.Enabled ? 2 : 1)
        SetStatus("Could not switch capture mode: " e.Message)
        return
    }
    Reload()
}

CapturePickerOwnWindow(hwnd) {
    ; Exclude every window in this OCR Boxes instance, including its menus/dialogs.
    try return WinGetPID("ahk_id " hwnd) = DllCall("GetCurrentProcessId", "uint")
    return true
}

CapturePickerWindowRect(hwnd) {
    if !DllCall("IsWindowVisible", "ptr", hwnd) || DllCall("IsIconic", "ptr", hwnd) || CapturePickerOwnWindow(hwnd)
        throw Error("Choose a visible, non-minimized application window.")
    cloaked := 0
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "uint*", &cloaked, "uint", 4) != 0 || cloaked
        throw Error("That application window is not available on this desktop.")
    WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
    if w < 24 || h < 16
        throw Error("That window is too small to read.")
    return {x: x, y: y, w: w, h: h}
}

ShowCapturePicker(*) {
    if GameSession.Enabled
        return
    pickerMenu := Menu()
    windows := Menu()
    count := 0
    for hwnd in WinGetList() {
        try {
            rect := CapturePickerWindowRect(hwnd)
            title := WinGetTitle("ahk_id " hwnd)
            if title = "" || (WinGetExStyle("ahk_id " hwnd) & 0x80)
                continue
            count += 1
            ; Titles are displayed only in this user-opened menu, never logged or saved.
            label := count ". " StrReplace(SubStr(title, 1, 70), "&", "&&")
            windows.Add(label, CapturePickerWindow.Bind(hwnd, WinGetPID("ahk_id " hwnd)))
        } catch
            continue
    }
    if !count {
        windows.Add("No visible application windows", (*) => 0)
        windows.Disable("No visible application windows")
    }
    displays := Menu()
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        displays.Add("Display " A_Index " (" (r-l) " x " (b-t) ")", CapturePickerDisplay.Bind(MonitorGetName(A_Index)))
    }
    pickerMenu.Add("Fit box to visible window", windows)
    pickerMenu.Add("Fit box to entire display", displays)
    pickerMenu.Add("Add movable region", (*) => AddBox())
    pickerMenu.Show()
}

CapturePickerWindow(hwnd, pid, *) {
    if GameSession.Enabled
        return
    try {
        if WinGetPID("ahk_id " hwnd) != pid
            throw Error("That window changed. Open the picker again.")
        CapturePickerAdd(CapturePickerWindowRect(hwnd))
    } catch as e
        SetStatus("Cannot select window: " e.Message)
}
CapturePickerDisplay(name, *) {
    if GameSession.Enabled
        return
    Loop MonitorGetCount() {
        if MonitorGetName(A_Index) = name {
            MonitorGet(A_Index, &l, &t, &r, &b)
            CapturePickerAdd({x:l, y:t, w:r-l, h:b-t})
            return
        }
    }
    SetStatus("That display was disconnected. Open the picker again.")
}
CapturePickerAdd(rect) {
    if GameSession.Enabled
        return false
    ; Selection fits an editable box only. No pixels are read until the user locks and plays.
    slot := 0
    Loop MaxBoxes
        if !Boxes[A_Index] {
            slot := A_Index
            break
        }
    if !slot {
        SetStatus("Four boxes is the maximum. Remove one before fitting another.")
        return false
    }
    Boxes[slot] := OcrBox(slot, rect.x, rect.y, rect.w, rect.h)
    ; Gui placement includes a sizing border. Align its *client* capture area exactly.
    fitted := Boxes[slot]
    fitted.gui.GetPos(&gx, &gy, &gw, &gh)
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " fitted.gui.Hwnd)
    fitted.gui.Move(gx + rect.x - cx, gy + rect.y - cy, gw + rect.w - cw, gh + rect.h - ch)
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " fitted.gui.Hwnd)
    if cx != rect.x || cy != rect.y || cw != rect.w || ch != rect.h {
        fitted.Destroy()
        Boxes[slot] := 0
        SetStatus("That area is too small to fit exactly. Resize the window or use a movable region.")
        return false
    }
    Lanes[slot].Clear()
    Lanes[slot].lastNorm := ""
    SyncBar()
    SetStatus("Box fitted. Lock it and press Play. This is a fixed screen area: refit after moving/resizing the window; covering apps will be read instead.")
    return true
}
