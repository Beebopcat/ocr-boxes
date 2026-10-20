#Requires AutoHotkey v2.0
; Adapts Game Voice Reader's native Edge Read Aloud approach, not its global
; mouse/clipboard loop. Only this instance's escaped HTML page/window is used.
class EdgeBrowserSpeaker {
    static Configuring := false
    Name := "Edge Read Aloud (browser)"
    LastError := ""
    __New() {
        this.hwnd := 0
        this.epoch := 0
        this.started := 0
        this.paused := false
        this.over := true
        this.probePid := 0
        this.lastProbe := 0
        this.root := ""
        this.title := ""
        this.commandSeq := 0
    }
    EnsurePage(text) {
        if this.root = "" {
            DesktopReader.Init()
            this.root := DesktopReader.Root "\edge"
            DirCreate(this.root)
            this.title := "OCR Boxes Reader " SubStr(DesktopReader.Token,1,16)
        }
        text := StrReplace(StrReplace(StrReplace(text,"&","&amp;"),"<","&lt;"),">","&gt;")
        this.pageTitle := this.title "-" this.epoch
        html := '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>' this.pageTitle '</title><meta http-equiv="Content-Security-Policy" content="default-src ' "'none'" '; style-src ' "'unsafe-inline'" '"></head><body><main><article><p style="white-space:pre-wrap;font:24px Segoe UI">' text '</p></article></main></body></html>'
        path := this.root "\reading.html"
        file := FileOpen(path,"w","UTF-8")
        file.Write(html)
        file.Close()
        return path
    }
    OwnWindow() {
        if !this.hwnd || !WinExist("ahk_id " this.hwnd)
            return false
        try return WinGetProcessName("ahk_id " this.hwnd) = "msedge.exe" && InStr(WinGetTitle("ahk_id " this.hwnd),this.title) = 1
        return false
    }
    Start(text) {
        if Cfg.Get("voice","edgeBrowserFocusConsent","0") != "1"
            throw Error("Edge browser reading is off. Enable the focus-switch checkbox to use native Edge Read Aloud.")
        this.epoch += 1
        EdgeBrowserSpeaker.Configuring := true
        epoch := this.epoch
        previous := DllCall("GetForegroundWindow","ptr")
        try {
            page := this.EnsurePage(text)
            this.WriteEpoch()
            if !this.OwnWindow() {
                edge := this.FindEdge()
                Run('"' edge '" --new-window "' page '"')
                this.hwnd := WinWait(this.title " ahk_exe msedge.exe",,8)
            }
            if !this.OwnWindow() || epoch != this.epoch
                throw Error("The dedicated Edge reading window is not available.")
            WinActivate("ahk_id " this.hwnd)
            if !WinWaitActive("ahk_id " this.hwnd,,3)
                throw Error("Edge did not accept focus.")
            this.SendOwned("{F5}",epoch)
            this.WaitReady(epoch)
            this.SendOwned("^+u",epoch)
        } finally {
            restore := this.OwnWindow() && WinActive("ahk_id " this.hwnd) && previous && WinExist("ahk_id " previous)
            if this.OwnWindow()
                try WinMinimize("ahk_id " this.hwnd)
            if restore
                try WinActivate("ahk_id " previous)
            EdgeBrowserSpeaker.Configuring := false
        }
        if epoch != this.epoch
            throw Error("Edge reading was cancelled.")
        this.started := A_TickCount
        this.over := false
        this.paused := false
        this.LastError := ""
        this.lastProbe := 0
        this.probePid := 0
    }
    FindEdge() {
        for key in ["HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe","HKLM\Software\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe","HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"] {
            try {
                path := Trim(RegRead(key), '" ')
                if FileExist(path) && !InStr(FileExist(path),"D")
                    return path
            }
        }
        ; Some launchers omit ProgramFiles(x86); the Windows installation
        ; registry is a reliable fallback without changing the environment.
        roots := [A_ProgramFiles,EnvGet("LOCALAPPDATA")]
        for value in ["ProgramFilesDir (x86)","ProgramFilesDir"]
            try roots.Push(RegRead("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion",value))
        for root in roots {
            path := root "\Microsoft\Edge\Application\msedge.exe"
            if FileExist(path)
                return path
        }
        throw Error("Microsoft Edge was not found in its registered installation paths.")
    }
    SendOwned(keys,epoch) {
        ; Foreground accelerators are required by Chromium. The user explicitly
        ; opts into focus changes; never send if focus or this reading changed.
        Critical "On"
        try {
            if epoch != this.epoch || !this.OwnWindow() || !WinActive("ahk_id " this.hwnd)
                throw Error("Edge lost focus; reading cancelled. Press Play to retry.")
            Send(keys)
        } finally {
            Critical "Off"
        }
    }
    WaitReady(epoch) {
        deadline := A_TickCount+12000
        while A_TickCount < deadline {
            if epoch != this.epoch || !this.OwnWindow() || !WinActive("ahk_id " this.hwnd)
                throw Error("Edge lost focus before the reading page was ready.")
            this.Probe("ready")
            while ProcessExist(this.probePid) && A_TickCount < deadline {
                Sleep 50
                if epoch != this.epoch
                    throw Error("Edge reading was cancelled.")
            }
            if FileExist(this.probeOut) {
                status := Trim(FileRead(this.probeOut,"UTF-8")," `t`r`n" Chr(0xFEFF))
                try FileDelete(this.probeOut)
                this.probePid := 0
                if status = "ready"
                    return
            }
            if this.probePid && ProcessExist(this.probePid)
                break
            Sleep 100
        }
        throw Error("Edge did not finish loading the dedicated reading page.")
    }
    Probe(action) {
        if !this.OwnWindow()
            throw Error("The dedicated Edge reader was closed or navigated away.")
        helper := A_ScriptDir "\Lib\EdgeReadAloudControl.ps1"
        this.commandSeq += 1
        this.WriteEpoch()
        output := this.root "\status-" this.epoch "-" this.commandSeq ".txt"
        try FileDelete(output)
        exe := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
        Run('"' exe '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' helper '" -WindowHandle ' this.hwnd ' -ExpectedTitle "' (action = "ready" ? this.pageTitle : this.title) '" -Action ' action ' -Guard "' this.root '\epoch.txt" -ExpectedEpoch "' this.epoch "-" this.commandSeq '" -Output "' output '"',,"Hide",&pid)
        this.probePid := pid
        this.probeOut := output
        this.lastProbe := A_TickCount
    }
    WriteEpoch() {
        if this.root != "" {
            file := FileOpen(this.root "\epoch.txt","w","UTF-8-RAW")
            file.Write(this.epoch "-" this.commandSeq)
            file.Close()
        }
    }
    Busy() {
        if this.over
            return false
        if this.paused
            return true
        if !this.OwnWindow() {
            this.LastError := "The dedicated Edge reader was closed or navigated away."
            this.over := true
            return false
        }
        if this.probePid && FileExist(this.probeOut) {
            status := Trim(FileRead(this.probeOut,"UTF-8")," `t`r`n" Chr(0xFEFF))
            try FileDelete(this.probeOut)
            this.probePid := 0
            if status = "playing"
                return true
            if status = "stopped" && A_TickCount-this.started > 1500 {
                this.over := true
                return false
            }
            if status = "error" || A_TickCount-this.started > 15000 {
                this.LastError := "Edge Read Aloud did not expose usable playback controls. Open the dedicated reader to check its voice/settings."
                this.Stop()
                return false
            }
        }
        if this.probePid && ProcessExist(this.probePid) && A_TickCount-this.lastProbe > 5000 {
            this.LastError := "Edge playback-control check timed out."
            this.Stop()
            return false
        }
        if this.probePid && !ProcessExist(this.probePid) && !FileExist(this.probeOut) && A_TickCount-this.lastProbe > 1000 {
            this.LastError := "Edge playback-control check did not return a result."
            this.Stop()
            return false
        }
        if !this.probePid && A_TickCount-this.lastProbe >= 600 {
            try this.Probe("status")
            catch as error {
                this.LastError := error.Message
                this.Stop()
                return false
            }
        }
        return true
    }
    Stop() {
        this.epoch += 1
        this.WriteEpoch()
        this.over := true
        this.paused := false
        EdgeBrowserSpeaker.Configuring := false
        if this.OwnWindow()
            try WinClose("ahk_id " this.hwnd) ; this dedicated one-page reader only, never an unrelated Edge window
        if this.root != ""
            try FileDelete(this.root "\reading.html")
    }
    Pause() {
        if !this.over {
            this.Probe("pause")
            this.paused := true
        }
    }
    Resume() {
        if this.paused {
            this.Probe("resume")
            this.paused := false
        }
    }
}
