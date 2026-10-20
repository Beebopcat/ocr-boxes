#Requires AutoHotkey v2.0
; ============================================================================
;  BoxIO.ahk - settings, log, HTTP to the local services, JSON snippets and the screen sampling used by OCR Boxes.
;  Everything that talks to the outside world is here; the logic that decides what to read is in BoxLogic.ahk.
; ============================================================================

; ---- settings: "OCR Boxes.ini" next to the script (never committed) ----------------------------------------------------
class Cfg {
    static File := A_ScriptDir "\OCR Boxes.ini"
    static Get(section, key, default := "") => IniRead(Cfg.File, section, key, default)
    static Num(section, key, default, lo, hi) {
        v := IniRead(Cfg.File, section, key, default)
        try
            v := Float(v)
        catch
            v := default
        return Min(Max(v, lo), hi)
    }
    static Set(section, key, value) {
        try IniWrite(value, Cfg.File, section, key)
    }
    static Ensure() {
        if FileExist(Cfg.File)
            return
        FileAppend("; OCR Boxes settings.  Edit, then use the tray menu > Reload.`n"
            . "[ocr]`n; windows | rapid | vlm`nengine=windows`n; en-US is used when installed; set another tag (for example de-DE) to read another language`nlang=`ngoodScore=4`n"
            . "[voice]`n; edge (Edge natural voices over the internet, through the RapidOCR helper) | sapi (the same voices through a SAPI adapter) | kokoro | eleven`nengine=edge`n"
            . "; edge: ava | brian | ryan (UK) - the only voices used; edgeRate is -50..100 (percent)`nedgeVoice=ava`nedgeRate=0`n"
            . "sapiVoice=`nsapiRate=0`nkokoroVoice=`nkokoroSpeed=1.0`n"
            . "[eleven]`n; the API key is NOT kept here: set the ELEVENLABS_API_KEY environment variable or put it in %APPDATA%\PixelCompanions\elevenlabs.key`nvoiceId=`nmodel=eleven_flash_v2_5`n"
            . "[vlm]`n; Leave model empty: OCR Boxes then finds a vision model in Ollama or LM Studio by itself.  A model named here always wins (backend ollama | lmstudio); it must be a VISION model (a text-only model such as qwen3 cannot read a picture)`nbackend=ollama`nmodel=`nurl=http://127.0.0.1:11434`n"
            . "[watch]`n; how often every locked box is looked at`npollMs=100`n; a box counts as changed when this many percent of it differs`nchangePercent=1.5`n"
            . "; ... and as finished changing when no more than this many percent still moves between two looks`nsettlePercent=0.06`nsettleLooks=2`nmaxSettleMs=2500`n"
            . "boxAlpha=90`n"
            . "[reader]`n; box = Box 1, 2, 3, 4, Luna in turn (oldest line of each) | time = strictly in the order the text appeared`norder=box`n"
            . "[luna]`n; Luna Translator's text socket, for example ws://127.0.0.1:2333/api/ws/text/origin  (the port is in Luna's own settings)`nurl=`nexe=`n"
            . "[helper]`n; Use a separate loopback port if another program owns an incompatible helper. Never stop that program automatically.`n; 8801 is OCR Boxes' own port: Game Voice Reader's older helper keeps 8799 and has no Edge voice routes.`nurl=" Helper.DefaultUrl "`n"
            . "; the RapidOCR helper (rapid_server.py). Empty = ..\rapidocr-helper\rapid_server.py next to this folder, else dir\rapid_server.py`nscript=`n"
            . "dir=C:\AI_Workspace\tools\rapidocr-gvr`npython=`n"
            . "[kokoro]`nurl=http://127.0.0.1:8787`n", Cfg.File, "UTF-16")        ; UTF-16: Windows' ini functions then read non-ASCII voice names and paths correctly
    }
}

; ---- log: timings and states only, never the text that was read ----------------------------------------------------------
class Logger {
    static Dir := Cfg.Get("runtime","logDir",EnvGet("LOCALAPPDATA") "\OcrBoxes")
    static File := Logger.Dir "\boxes.log"
}
Log(msg) {
    try {
        DirCreate(Logger.Dir)
        if FileExist(Logger.File) && FileGetSize(Logger.File) > 524288
            FileMove(Logger.File, Logger.File ".old", 1)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " msg "`n", Logger.File, "UTF-8")
    }
}


; Only files created in this namespace are reaped. A live process's files are retained.
class SnapshotFiles {
    static Dir := Cfg.Get("runtime","snapshotDir",A_Temp)
    static Owned := Map()
    static Seq := 0
    static NewPath(box) {
        DirCreate(SnapshotFiles.Dir)
        SnapshotFiles.Seq += 1
        path := SnapshotFiles.Dir "\ocrbox-v2-" DllCall("GetCurrentProcessId") "-" SnapshotFiles.Seq "-box" box ".bmp"
        SnapshotFiles.Owned[path] := true
        return path
    }
    static Delete(path) {
        if !SnapshotFiles.Owned.Has(path)
            return
        try FileDelete(path)
        if !FileExist(path)
            SnapshotFiles.Owned.Delete(path)
    }
    static Cleanup() {
        paths := []
        for path in SnapshotFiles.Owned
            paths.Push(path)
        for path in paths
            SnapshotFiles.Delete(path)
    }
    static ReapOld() {
        Loop Files SnapshotFiles.Dir "\ocrbox-v2-*.bmp", "F" {
            if !RegExMatch(A_LoopFileName, "^ocrbox-v2-(\d+)-\d+-box[1-4]\.bmp$", &m)
                continue
            ; FILE_ATTRIBUTE_REPARSE_POINT: never follow or delete a link.
            if DllCall("GetFileAttributesW", "str", A_LoopFileFullPath, "uint") & 0x400
                continue
            if !ProcessExist(Integer(m[1]))
                try FileDelete(A_LoopFileFullPath)
        }
    }
}

; ---- HTTP (local services only) ------------------------------------------------------------------------------------------
Utf8Body(s) {
    n := StrPut(s, "UTF-8") - 1
    buf := Buffer(n + 1)
    StrPut(s, buf, n + 1, "UTF-8")
    arr := ComObjArray(0x11, n)
    pv := NumGet(ComObjValue(arr), 8 + A_PtrSize, "ptr")
    DllCall("RtlMoveMemory", "ptr", pv, "ptr", buf, "uptr", n)
    return arr
}

; Is anything listening on this local TCP port (IPv4)?  Asking Windows takes microseconds.  Connecting to a port nobody listens on takes about 2 seconds
; (Windows retries the connection), and a synchronous call freezes everything for those seconds - in OCR Boxes that is the 100 ms look at every box, so a line that
; is on screen for two seconds was missed while the RapidOCR helper was starting.  True when it cannot tell, so that the real request decides.
PortListening(port) {
    size := 0
    DllCall("iphlpapi\GetExtendedTcpTable", "ptr", 0, "uint*", &size, "int", 0, "uint", 2, "int", 3, "uint", 0)       ; AF_INET, TCP_TABLE_OWNER_PID_LISTENER: asks for the size
    if size < 4
        return true
    buf := Buffer(size + 256, 0)
    size := buf.Size
    if DllCall("iphlpapi\GetExtendedTcpTable", "ptr", buf, "uint*", &size, "int", 0, "uint", 2, "int", 3, "uint", 0) != 0
        return true
    Loop NumGet(buf, 0, "uint") {
        p := NumGet(buf, 4 + (A_Index - 1) * 24 + 8, "uint")                ; MIB_TCPROW_OWNER_PID: state, local addr, local port (network byte order), ...
        if (((p & 0xFF) << 8) | ((p >> 8) & 0xFF)) = port
            return true
    }
    return false
}

; Synchronous, direct (never through a proxy).  Returns {status, text}; status 0 = could not connect.
Http(method, url, body := "", timeoutMs := 4000) {
    r := {status: 0, text: ""}
    if RegExMatch(url, "i)^https?://127\.0\.0\.1:(\d+)", &lm) && !PortListening(Integer(lm[1])) {
        r.text := "nothing is listening on port " lm[1]
        return r
    }
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetProxy(1)
        req.SetTimeouts(1500, 1500, timeoutMs, timeoutMs)
        req.Open(method, url, false)
        if method = "POST" {
            req.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
            req.Send(Utf8Body(body))
        } else
            req.Send()
        r.status := req.Status
        r.text := req.ResponseText
    } catch as e {
        r.text := e.Message
    }
    return r
}

; The same POST without waiting: the 100 ms looks at the boxes keep running while a slow reader (RapidOCR, a vision model) works.
class AsyncPost {
    __New(url, body, timeoutMs := 30000) {
        this.done := false
        this.status := 0
        this.text := ""
        this.error := ""
        this.t0 := A_TickCount
        this.limit := timeoutMs
        try {
            this.req := ComObject("MSXML2.ServerXMLHTTP.6.0")
            this.req.open("POST", url, true)
            this.req.setProxy(1)                                 ; SXH_PROXY_SET_DIRECT: never via a proxy for a local service
            this.req.setTimeouts(1500, 1500, 5000, timeoutMs)
            this.req.setRequestHeader("Content-Type", "application/json; charset=utf-8")
            this.req.send(Utf8Body(body))
        } catch as e {
            this.done := true
            this.error := e.Message
        }
    }
    Abort() {
        this.done := true
        this.error := "cancelled"
        try this.req.abort()
    }
    ; True once the reply (or an error) is in.
    Poll() {
        if this.done
            return true
        try {
            if this.req.readyState = 4 {
                this.status := this.req.status
                this.text := this.req.responseText
                this.done := true
                return true
            }
        } catch as e {
            this.done := true
            this.error := e.Message
            return true
        }
        if A_TickCount - this.t0 > this.limit + 2000 {
            this.done := true
            this.error := "timed out"
            try this.req.abort()
            return true
        }
        return false
    }
}

; ---- JSON snippets (the services answer with flat objects, so a regex is enough) ------------------------------------------
JsonStr(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r`n", "\n")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\n")
    s := StrReplace(s, "`t", "\t")
    s := RegExReplace(s, "[\x00-\x1F]", " ")
    return '"' s '"'
}
JsonUnstr(s) {
    if !InStr(s, "\")
        return s
    out := ""
    i := 1
    n := StrLen(s)
    while i <= n {
        c := SubStr(s, i, 1)
        i += 1
        if c != "\" {
            out .= c
            continue
        }
        d := SubStr(s, i, 1)
        i += 1
        if d = "u" {
            cp := Integer("0x" SubStr(s, i, 4))
            i += 4
            if cp >= 0xD800 && cp <= 0xDBFF && SubStr(s, i, 2) = "\u" {
                lo := Integer("0x" SubStr(s, i + 2, 4))
                i += 6
                cp := 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            }
            out .= Chr(cp)
        } else if d = "n"
            out .= "`n"
        else if d = "t"
            out .= "`t"
        else if d = "r"
            out .= "`r"
        else if d = "b"
            out .= Chr(8)
        else if d = "f"
            out .= Chr(12)
        else
            out .= d
    }
    return out
}
JsonField(json, name) {
    if RegExMatch(json, '"' name '"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        return JsonUnstr(m[1])
    return ""
}
JsonTrue(json, name) {
    return RegExMatch(json, '"' name '"\s*:\s*true') ? true : false
}
JsonNumber(json, name) {
    return RegExMatch(json, '"' name '"\s*:\s*(-?[0-9.]+)', &m) ? Number(m[1]) : ""
}
; ["a","b"] under `key` -> an Array of strings
ParseStringArray(json, key) {
    out := []
    if !RegExMatch(json, '"' key '"\s*:\s*\[', &m)
        return out
    rest := SubStr(json, m.Pos + m.Len)
    while RegExMatch(rest, '^\s*"((?:[^"\\]|\\.)*)"\s*(,|\])?', &s) {
        out.Push(JsonUnstr(s[1]))
        rest := SubStr(rest, s.Len + 1)
        if s[2] != ","
            break
    }
    return out
}

; ---- the RapidOCR helper: also hosts the vision-model, ElevenLabs and Luna routes -----------------------------------------
class Helper {
    static DefaultUrl := "http://127.0.0.1:8801"                  ; OCR Boxes' own port; 8799 belongs to Game Voice Reader's older helper (no Edge voice routes)
    static Url := Cfg.Get("helper", "url", Helper.DefaultUrl)
    static request := Http
    static portListening := PortListening
    static startedAt := 0
    static known := false
    static checkedAt := 0
    static lastAnswer := ""
    static Health() {
        r := Helper.request.Call("GET",Helper.Url "/health","",1500)
        return r.status = 200 && (!GameSession.Enabled || JsonField(r.text,"reader_protocol") = "game-session-v1")
    }
    static HasExtras() {
        r := Helper.request.Call("GET", Helper.Url "/tts/status", "", 1500)
        return r.status = 200 && InStr(r.text, '"speaking"') > 0
    }
    static ScriptPath() {
        s := Cfg.Get("helper", "script", "")
        if s != "" && FileExist(s)
            return s
        near := A_ScriptDir "\..\rapidocr-helper\rapid_server.py"
        if FileExist(near)
            return near
        return Cfg.Get("helper", "dir", "C:\AI_Workspace\tools\rapidocr-gvr") "\rapid_server.py"
    }
    static PythonPath() {
        p := Cfg.Get("helper", "python", "")
        return p != "" ? p : Cfg.Get("helper", "dir", "C:\AI_Workspace\tools\rapidocr-gvr") "\.venv\Scripts\pythonw.exe"
    }
    ; Never blocks for long.  Returns "ready", "starting", or a sentence starting with "!" that says what is missing.
    ; The answer is remembered for a moment (3 s when ready, 1 s otherwise): the reader asks on every snapshot.
    static Ensure() {
        if Helper.lastAnswer != "" && A_TickCount - Helper.checkedAt < (Helper.lastAnswer = "ready" ? 3000 : 1000)
            return Helper.lastAnswer
        Helper.lastAnswer := Helper.EnsureNow()
        Helper.checkedAt := A_TickCount
        return Helper.lastAnswer
    }
    static Invalidate() {
        if Helper.lastAnswer = "ready"
            Helper.startedAt := 0
        Helper.known := false
        Helper.checkedAt := 0
        Helper.lastAnswer := ""
    }
    static EnsureNow() {
        if !RegExMatch(Helper.Url, "^http://127\.0\.0\.1:(\d+)$", &portMatch) || Integer(portMatch[1]) < 1 || Integer(portMatch[1]) > 65535
            return "!The helper address must be a local loopback port (1-65535)."
        if Helper.Health() {
            if Helper.known || Helper.HasExtras() {
                Helper.known := true
                return "ready"
            }
            ; This may belong to Game Voice Reader. Readiness is not process ownership.
            return "!Another helper is using this port without the OCR Boxes routes. Leave it running and set [helper] url to a separate loopback port."
        }
        Helper.known := false
        if Helper.startedAt && A_TickCount - Helper.startedAt < 45000
            return "starting"
        if Helper.portListening.Call(Integer(portMatch[1]))
            return "!The helper port is occupied but not ready. Leave the existing service running; choose another [helper] url or check that service."
        script := Helper.ScriptPath()
        py := Helper.PythonPath()
        if !FileExist(py)
            return "!The Python for the RapidOCR helper was not found (" py "). Set [helper] python in OCR Boxes.ini."
        if !FileExist(script)
            return "!rapid_server.py was not found (" script "). Set [helper] script in OCR Boxes.ini."
        if !FileExist(RegExReplace(script, "[^\\]+$") "extras.py") || !FileExist(RegExReplace(script, "[^\\]+$") "edge_tts.py")
            return "!extras.py and edge_tts.py must sit next to rapid_server.py (" script ")."
        Log("starting the RapidOCR helper: " script)
        try Run('"' py '" "' script '" --parent ' DllCall("GetCurrentProcessId") ' --port ' portMatch[1], RegExReplace(script, "\\[^\\]+$"), "Hide")
        catch as e
            return "!Could not start the helper: " e.Message
        Helper.startedAt := A_TickCount
        return "starting"
    }
}

; ---- screen: a small signature of a box (for the 100 ms looks) and a BMP file of a snapshot (for the helper) ----------------
class SigSize {
    static W := 80
    static H := 40
    static Cells := 3200
    static Bytes := 12800
    static LastError := 0                                             ; Windows error code of the last failed SampleSig
}

; One StretchBlt of the box down to 80x40 (about 10-16 ms, even in a game; PixelGetColor would take 0.5 s per pixel).
; Returns false when Windows could not copy the screen this time (the buffer is then NOT updated: a failed copy is a blank picture, not a change).
SampleSig(r, buf, blit := 0) {
    oldDpi := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    hdcMem := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcScreen, "int", SigSize.W, "int", SigSize.H, "ptr")
    old := DllCall("SelectObject", "ptr", hdcMem, "ptr", hbm, "ptr")
    DllCall("SetStretchBltMode", "ptr", hdcMem, "int", 4)             ; HALFTONE: average the pixels instead of skipping them
    ok := blit ? blit.Call(hdcMem, hdcScreen, r, SigSize.W, SigSize.H) : DllCall("StretchBlt", "ptr", hdcMem, "int", 0, "int", 0, "int", SigSize.W, "int", SigSize.H, "ptr", hdcScreen, "int", r.x, "int", r.y, "int", r.w, "int", r.h, "uint", 0x00CC0020 | OCR.CAPTUREBLT, "int")   ; as the OCR library: CAPTUREBLT only without DWM (it flickers the cursor)
    if !ok
        SigSize.LastError := A_LastError
    bi := Buffer(40, 0)
    NumPut("uint", 40, bi, 0)
    NumPut("int", SigSize.W, bi, 4)
    NumPut("int", -SigSize.H, bi, 8)
    NumPut("ushort", 1, bi, 12)
    NumPut("ushort", 32, bi, 14)
    DllCall("SelectObject", "ptr", hdcMem, "ptr", old)             ; GetDIBits requires an unselected bitmap
    pixels := Buffer(SigSize.Bytes, 0)
    if ok
        ok := DllCall("GetDIBits", "ptr", hdcMem, "ptr", hbm, "uint", 0, "uint", SigSize.H, "ptr", pixels, "ptr", bi, "uint", 0, "int") = SigSize.H
    if ok
        DllCall("RtlMoveMemory", "ptr", buf, "ptr", pixels, "uptr", SigSize.Bytes)
    else
        SigSize.LastError := A_LastError
    DllCall("SelectObject", "ptr", hdcMem, "ptr", old)
    DllCall("DeleteObject", "ptr", hbm)
    DllCall("DeleteDC", "ptr", hdcMem)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
    DllCall("SetThreadDpiAwarenessContext", "ptr", oldDpi, "ptr")
    return ok ? true : false
}

; The same 80x40 signature, made from a snapshot that was already taken (HBITMAP of w x h pixels): used to check that the picture did not change between the
; look that decided to take the snapshot and the moment the snapshot was copied.  Returns false when the copy fails.
SigOfBitmap(hbmSnap, w, h, buf) {
    oldDpi := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    hdcSrc := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
    oldSrc := DllCall("SelectObject", "ptr", hdcSrc, "ptr", hbmSnap, "ptr")
    hdcMem := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcScreen, "int", SigSize.W, "int", SigSize.H, "ptr")
    old := DllCall("SelectObject", "ptr", hdcMem, "ptr", hbm, "ptr")
    DllCall("SetStretchBltMode", "ptr", hdcMem, "int", 4)
    ok := DllCall("StretchBlt", "ptr", hdcMem, "int", 0, "int", 0, "int", SigSize.W, "int", SigSize.H, "ptr", hdcSrc, "int", 0, "int", 0, "int", w, "int", h, "uint", 0x00CC0020, "int")
    bi := Buffer(40, 0)
    NumPut("uint", 40, bi, 0)
    NumPut("int", SigSize.W, bi, 4)
    NumPut("int", -SigSize.H, bi, 8)
    NumPut("ushort", 1, bi, 12)
    NumPut("ushort", 32, bi, 14)
    DllCall("SelectObject", "ptr", hdcMem, "ptr", old)
    pixels := Buffer(SigSize.Bytes, 0)
    if ok
        ok := DllCall("GetDIBits", "ptr", hdcMem, "ptr", hbm, "uint", 0, "uint", SigSize.H, "ptr", pixels, "ptr", bi, "uint", 0, "int") = SigSize.H
    if ok
        DllCall("RtlMoveMemory", "ptr", buf, "ptr", pixels, "uptr", SigSize.Bytes)
    DllCall("SelectObject", "ptr", hdcMem, "ptr", old)
    DllCall("DeleteObject", "ptr", hbm)
    DllCall("DeleteDC", "ptr", hdcMem)
    DllCall("SelectObject", "ptr", hdcSrc, "ptr", oldSrc)
    DllCall("DeleteDC", "ptr", hdcSrc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
    DllCall("SetThreadDpiAwarenessContext", "ptr", oldDpi, "ptr")
    return ok ? true : false
}

; Writes the HBITMAP (a snapshot from OCR.CreateHBitmap) as a 32-bit .bmp file.  Returns the width x height as {w, h}.
SaveBmp(hbm, path) {
    hdc := DllCall("GetDC", "ptr", 0, "ptr")
    bi := Buffer(40, 0)
    NumPut("uint", 40, bi, 0)
    DllCall("GetDIBits", "ptr", hdc, "ptr", hbm, "uint", 0, "uint", 0, "ptr", 0, "ptr", bi, "uint", 0)     ; fills in width and height
    w := NumGet(bi, 4, "int")
    h := NumGet(bi, 8, "int")
    if w <= 0 || h <= 0 {
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
        throw Error("snapshot has no size")
    }
    NumPut("ushort", 1, bi, 12)
    NumPut("ushort", 32, bi, 14)
    NumPut("uint", 0, bi, 16)                                         ; BI_RGB; a positive height stores the rows bottom-up, as .bmp files do
    NumPut("int", h, bi, 8)
    size := w * 4 * h
    pix := Buffer(size)
    copied := DllCall("GetDIBits", "ptr", hdc, "ptr", hbm, "uint", 0, "uint", h, "ptr", pix, "ptr", bi, "uint", 0, "int")
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
    if copied != h
        throw Error("could not read all snapshot rows")
    hdr := Buffer(14, 0)
    NumPut("ushort", 0x4D42, hdr, 0)
    NumPut("uint", 54 + size, hdr, 2)
    NumPut("uint", 54, hdr, 10)
    f := FileOpen(path, "w")
    f.RawWrite(hdr, 14)
    f.RawWrite(bi, 40)
    f.RawWrite(pix, size)
    f.Close()
    return {w: w, h: h}
}


