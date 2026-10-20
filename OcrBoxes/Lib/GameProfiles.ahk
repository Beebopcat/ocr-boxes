#Requires AutoHotkey v2.0
; Profile data is not an execution path. No game, injector or model is launched here.
class GameJsonLiteral {
    __New(value) => this.value := value
}
class GameJson {
    static Load(text) {
        if StrLen(text) > 2097152
            throw Error("Profile JSON is too large")
        reader := GameJson(text)
        value := reader.Read()
        reader.Space()
        if reader.pos <= StrLen(text)
            throw Error("Trailing JSON data")
        return value
    }
    __New(text) {
        this.text := text, this.pos := 1, this.depth := 0
    }
    Space() {
        while this.pos <= StrLen(this.text) && InStr(" `t`r`n" Chr(0xFEFF), SubStr(this.text, this.pos, 1))
            this.pos += 1
    }
    Read() {
        this.Space()
        this.depth += 1
        if this.depth > 16
            throw Error("JSON nesting is too deep")
        try {
            c := SubStr(this.text, this.pos, 1)
            if c = "{" {
                this.pos += 1, out := Map()
                this.Space()
                if SubStr(this.text, this.pos, 1) = "}" {
                    this.pos += 1
                    return out
                }
                loop {
                    this.Space()
                    key := this.String()
                    if out.Has(key)
                        throw Error("Duplicate JSON property")
                    this.Space()
                    if SubStr(this.text, this.pos++, 1) != ":"
                        throw Error("Expected JSON colon")
                    out[key] := this.Read()
                    this.Space()
                    end := SubStr(this.text, this.pos++, 1)
                    if end = "}"
                        return out
                    if end != ","
                        throw Error("Expected JSON comma")
                }
            } else if c = "[" {
                this.pos += 1, out := []
                this.Space()
                if SubStr(this.text, this.pos, 1) = "]" {
                    this.pos += 1
                    return out
                }
                loop {
                    out.Push(this.Read())
                    this.Space()
                    end := SubStr(this.text, this.pos++, 1)
                    if end = "]"
                        return out
                    if end != ","
                        throw Error("Expected JSON comma")
                }
            } else if c = '"' {
                return this.String()
            } else if RegExMatch(SubStr(this.text, this.pos), "^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?", &m) {
                this.pos += m.Len
                return Number(m[0])
            } else {
                for literal in ["true", "false", "null"]
                    if SubStr(this.text, this.pos, StrLen(literal)) = literal {
                        this.pos += StrLen(literal)
                        return GameJsonLiteral(literal)
                    }
                throw Error("Invalid JSON value")
            }
        } finally {
            this.depth -= 1
        }
    }
    String() {
        if !RegExMatch(SubStr(this.text, this.pos), '^"((?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*)"', &m)
            throw Error("Invalid JSON string")
        this.pos += m.Len
        value := JsonUnstr(m[1])
        return value
    }
    static Dump(value) {
        if value is GameJsonLiteral
            return value.value
        if value is Array {
            out := ""
            for item in value
                out .= (out = "" ? "" : ",") GameJson.Dump(item)
            return "[" out "]"
        }
        if value is Map {
            out := ""
            for key, item in value
                out .= (out = "" ? "" : ",") JsonStr(key) ":" GameJson.Dump(item)
            return "{" out "}"
        }
        if Type(value) = "Integer" || Type(value) = "Float"
            return value ""
        return JsonStr(value)
    }
}
class GameProfiles {
    static File := A_ScriptDir "\game-profiles.json"
    static Data := 0
    static Current := 0
    static AllowedIDs := Map("637090",1,"1812450",1,"3321460",1,"975370",1,"2622380",1,"1905530",1,"677120",1,"1282730",1,"1129580",1,"294100",1,"1155970",1,"1374490",1,"512900",1,"4957080",1,"1222670",1,"470310",1)
    static Load() {
        data := GameJson.Load(FileRead(GameProfiles.File, "UTF-8"))
        if !(data is Map) || data.Get("schemaVersion", 0) != 1 || !(data.Get("games", 0) is Array) || data["games"].Length != 16
            throw Error("Expected the fixed sixteen-game profile catalogue")
        seen := Map()
        for p in data["games"] {
            GameProfiles.Validate(p)
            p["lunaSelection"] := Map() ; runtime receipts are never restored from profile JSON
            id := p["SteamAppID"]
            if seen.Has(id)
                throw Error("Duplicate Steam profile")
            seen[id] := true
        }
        GameProfiles.Data := data
        ; Deliberately never activate the previously selected profile at startup.
        GameProfiles.Current := 0
    }
    static Validate(p) {
        if !(p is Map) || !GameProfiles.AllowedIDs.Has(p.Get("SteamAppID", ""))
            throw Error("Game is outside the approved sixteen-profile catalogue")
        for key in ["name","exe","build","manifest","source","engine","voice","protection","validation","lunaCompatibility","lunaIsolation"]
            if !p.Has(key) || Type(p[key]) != "String"
                throw Error("Invalid game-profile field: " key)
        if p["source"] != "ocr-boxes" && p["source"] != "luna-ocr" && p["source"] != "luna-hook"
            throw Error("Invalid game text source")
        if p["engine"] != "windows" && p["engine"] != "rapid"
            throw Error("Only CPU Windows/RapidOCR are supported by game profiles")
        if p["protection"] != "unknown" && p["protection"] != "protected" && p["protection"] != "unprotected-confirmed" && p["protection"] != "controlled-test-reviewed"
            throw Error("Invalid game protection classification")
        if !RegExMatch(p["build"], "^\d+$") || !RegExMatch(p["manifest"], "i)\\appmanifest_" p["SteamAppID"] "\.acf$")
            throw Error("Invalid saved Steam build identity")
        if !(p.Get("candidateExes", 0) is Array) || !p["candidateExes"].Length
            throw Error("Missing curated executable candidates")
        if !(p.Get("clientRelativeROI", 0) is Array) || p["clientRelativeROI"].Length > 4
            throw Error("Invalid client-relative OCR regions")
        for r in p["clientRelativeROI"]
            GameProfiles.ValidateROI(r)
        if !IsNumber(p.Get("speed", "")) || p["speed"] < 0.5 || p["speed"] > 2.0
            throw Error("Invalid voice speed")
        if p["protection"] != "unprotected-confirmed"
            p["voice"] := "af_heart"
        if !GameProfiles.LunaPolicyAllowed(p)
            p["source"] := "ocr-boxes" ; fail closed; never upgrade a profile by guessing
    }
    static ValidateROI(r) {
        if !(r is Map)
            throw Error("Invalid OCR region")
        for k in ["x","y","w","h"]
            if !r.Has(k) || !IsNumber(r[k])
                throw Error("Invalid OCR region coordinates")
        if r["x"] < 0 || r["y"] < 0 || r["w"] <= 0 || r["h"] <= 0 || r["x"] + r["w"] > 1 || r["y"] + r["h"] > 1
            throw Error("OCR region must fit inside the selected game client")
    }
    static LunaPolicyAllowed(p) => LunaReceipt.PolicyOK(p)
    static LunaAllowed(p) => GameProfiles.LunaPolicyAllowed(p) && GameProfiles.SelectionReviewed(p)
    static SelectionReviewed(p) {
        selection := p.Get("lunaSelection",0)
        if !(selection is Map)
            return false
        try {
            LunaReceipt.Validate(selection,p,
                {pid:selection["game_pid"],hwnd:selection["game_hwnd"],created:selection["process_creation_filetime"],exe:p["exe"]},
                p["exe_sha256"])
            return true
        }
        return false
    }
    static Serializable() {
        copy := GameJson.Load(GameJson.Dump(GameProfiles.Data))
        for profile in copy["games"]
            profile["lunaSelection"] := Map()
        return copy
    }
    static Choose(ctrl, *) {
        GameSession.Suspend("profile-switch", true)
        GameProfiles.Current := ctrl.Value > 1 ? GameProfiles.Data["games"][ctrl.Value - 1] : 0
        if !GameProfiles.Current
            return
        p := GameProfiles.Current
        Cfg.Set("ocr", "engine", p["engine"])
        Cfg.Set("voice", "engine", "kokoro")
        Cfg.Set("voice", "kokoroVoice", p["voice"])
        Cfg.Set("voice", "kokoroSpeed", p["speed"])
        ChooseSpeaker("kokoro")
        BarCtl.ocr.Choose(IndexOf(OcrKeys, p["engine"]))
        BarCtl.eng.Choose(IndexOf(VoiceKeys, "kokoro"))
        BarCtl.profileSource.Choose(IndexOf(["ocr-boxes","luna-ocr","luna-hook"], p["source"]))
        RefreshVoiceList()
        SetStatus("Selected " p["name"] ". Bind its foreground window; reading stays stopped.")
    }
    static SourceChanged(ctrl, *) {
        if !GameProfiles.Current
            return
        p := GameProfiles.Current
        wanted := ["ocr-boxes","luna-ocr","luna-hook"][ctrl.Value]
        old := p["source"]
        p["source"] := wanted
        if wanted != "ocr-boxes" && !GameProfiles.LunaPolicyAllowed(p) {
            p["source"] := old
            ctrl.Choose(IndexOf(["ocr-boxes","luna-ocr","luna-hook"], old))
            SetStatus("This build has no verified permitted Luna source. Direct CPU OCR remains selected.")
            return
        }
        GameSession.Suspend("source-switch")
        SetStatus("Source changed. Explicit Resume is required.")
    }
    static Save(*) {
        if !GameProfiles.Current || !GameSession.IdentityOK(false) {
            SetStatus("Bind the selected game window before saving its profile.")
            return
        }
        p := GameProfiles.Current
        rois := []
        bounds := GameSession.Bounds()
        for b in Boxes {
            if !b || !b.locked
                continue
            r := Map("x", (b.rect.x-bounds.x)/bounds.w, "y", (b.rect.y-bounds.y)/bounds.h,
                     "w", b.rect.w/bounds.w, "h", b.rect.h/bounds.h)
            GameProfiles.ValidateROI(r)
            b.relativeROI := r
            rois.Push(r)
        }
        p["exe"] := GameSession.Exe
        p["clientRelativeROI"] := rois
        p["engine"] := Cfg.Get("ocr", "engine", "windows")
        p["voice"] := p["protection"] = "unprotected-confirmed" ? Nz(Spk.voice,"af_heart") : "af_heart"
        p["speed"] := Spk.speed
        GameProfiles.Validate(p)
        GameProfiles.Data["selectedSteamAppID"] := p["SteamAppID"]
        temp := GameProfiles.File "." A_TickCount ".tmp"
        try {
            FileAppend(GameJson.Dump(GameProfiles.Serializable()) "`n", temp, "UTF-8-RAW")
            FileMove(temp, GameProfiles.File, 1)
        } finally {
            if FileExist(temp)
                FileDelete(temp)
        }
        SetStatus("Profile saved; validation remains " p["validation"] ". Resume explicitly in the game.")
    }
}
class GameSession {
    static Enabled := true
    static Bound := false
    static Armed := false
    static Epoch := 0
    static Pid := 0
    static Hwnd := 0
    static Created := ""
    static Exe := ""
    static Token := ""
    static Client := "ocrboxes-" DllCall("GetCurrentProcessId") "-" DllCall("GetTickCount64", "uint64")
    static LunaSource := ""
    static LunaGeneration := 0
    static LunaSequence := 0
    static ForegroundHook := 0
    static ForegroundCallback := 0
    static FocusLost := false
    static FocusFlushCallback := 0
    static SelectionAfter := 0
    static LastLunaKey := ""
    static Drops := Map("capture",0,"text",0,"speech",0,"invalidations",0,"snapshot_overflow",0,"luna",0)
    static Identity(hwnd) {
        if !hwnd || !DllCall("IsWindow","ptr",hwnd,"int")
            throw Error("Game window is unavailable")
        pid := 0
        DllCall("GetWindowThreadProcessId","ptr",hwnd,"uint*",&pid,"uint")
        handle := DllCall("OpenProcess","uint",0x1000,"int",0,"uint",pid,"ptr")
        if !handle
            throw Error("Game process identity cannot be read")
        c := Buffer(8), e := Buffer(8), k := Buffer(8), u := Buffer(8)
        try {
            if !DllCall("GetProcessTimes","ptr",handle,"ptr",c,"ptr",e,"ptr",k,"ptr",u,"int")
                throw Error("Game process creation time cannot be read")
            created := NumGet(c,0,"uint64") ""
        } finally {
            DllCall("CloseHandle","ptr",handle)
        }
        return {pid:pid, hwnd:hwnd, created:created, exe:WinGetProcessPath("ahk_id " hwnd)}
    }
    static InstallForegroundGuard() {
        GameSession.ForegroundCallback := CallbackCreate(ObjBindMethod(GameSession,"OnForeground"),"",7)
        ; WINEVENT_OUTOFCONTEXT (0): callback stays in this process; no injection into games.
        GameSession.ForegroundHook := DllCall("SetWinEventHook","uint",3,"uint",3,"ptr",0,
            "ptr",GameSession.ForegroundCallback,"uint",0,"uint",0,"uint",0,"ptr")
        return !!GameSession.ForegroundHook
    }
    static RemoveForegroundGuard() {
        if GameSession.ForegroundHook
            DllCall("UnhookWinEvent","ptr",GameSession.ForegroundHook)
        GameSession.ForegroundHook := 0
        if GameSession.ForegroundCallback
            CallbackFree(GameSession.ForegroundCallback)
        GameSession.ForegroundCallback := 0
    }
    static OnForeground(hook,event,hwnd,objectId,childId,eventThread,eventTime) {
        if GameSession.Armed && hwnd != GameSession.Hwnd {
            GameSession.Armed := false
            GameSession.Epoch += 1
            GameSession.FocusLost := true
            if !GameSession.FocusFlushCallback
                GameSession.FocusFlushCallback := ObjBindMethod(GameSession,"FlushFocusLoss")
            SetTimer(GameSession.FocusFlushCallback,-1)
        }
    }
    static FlushFocusLoss() {
        if GameSession.FocusLost
            GameSession.Suspend("foreground-event")
    }
    static LunaSelectionOK() {
        p := GameProfiles.Current
        if !p || !GameProfiles.SelectionReviewed(p)
            return false
        try {
            current := LunaReceipt.Validate(LunaReceipt.Read(p),p,
                {pid:GameSession.Pid,hwnd:GameSession.Hwnd,created:GameSession.Created,exe:GameSession.Exe},p["exe_sha256"])
            return GameJson.Dump(current) = GameJson.Dump(p["lunaSelection"])
        }
        return false
    }
    static AcquireLuna() {
        p := GameProfiles.Current
        if !GameProfiles.LunaPolicyAllowed(p)
            throw Error("Current game/build has no reviewed permitted Luna policy")
        manifest := FileRead(p["manifest"],"UTF-8")
        if !RegExMatch(manifest,'"buildid"\s+"(\d+)"',&m) || m[1] != p["build"]
            throw Error("Steam build changed; review this profile")
        id := GameSession.Identity(GameSession.Hwnd)
        selected := LunaReceipt.Acquire(p,id,GameSession.SelectionAfter,GameSession.LastLunaKey)
        key := selected["source_session"] ":" selected["source_generation"]
        if key = GameSession.LastLunaKey || !GameSession.IdentityOK()
            throw Error("A fresh Luna Bind/re-arm in this game is required")
        p["lunaSelection"] := selected ; pin before the consumer client/epoch is issued
    }
    static BindLater(*) {
        GameSession.Suspend("bind-window", true)
        SetStatus("Switch to the selected game's window within three seconds. Binding will not start reading.")
        SetTimer(ObjBindMethod(GameSession,"BindForeground"), -3000)
    }
    static BindForeground() {
        if !GameProfiles.Current {
            SetStatus("Select a game profile first.")
            return
        }
        try {
            p := GameProfiles.Current
            id := GameSession.Identity(DllCall("GetForegroundWindow","ptr"))
            match := false
            for candidate in p["candidateExes"]
                if StrLower(candidate) = StrLower(id.exe)
                    match := true
            if !match || (p["exe"] != "" && StrLower(p["exe"]) != StrLower(id.exe))
                throw Error("Foreground executable does not match the selected game profile")
            manifest := FileRead(p["manifest"], "UTF-8")
            if !RegExMatch(manifest, '"buildid"\s+"(\d+)"', &m) || m[1] != p["build"]
                throw Error("Steam build changed; review the profile before using it")
            GameSession.Pid := id.pid, GameSession.Hwnd := id.hwnd
            GameSession.Created := id.created, GameSession.Exe := id.exe
            GameSession.Bound := true
            GameSession.SelectionAfter := LunaReceipt.NowFileTime()
            ; Saved ROIs use client fractions and never a global desktop rectangle.
            for b in Boxes
                if b
                    b.Destroy()
            Loop MaxBoxes
                Boxes[A_Index] := 0
            bounds := GameSession.Bounds()
            for i, r in p["clientRelativeROI"] {
                b := OcrBox(i, bounds.x+Round(r["x"]*bounds.w), bounds.y+Round(r["y"]*bounds.h),
                            Round(r["w"]*bounds.w), Round(r["h"]*bounds.h))
                Boxes[i] := b
                b.relativeROI := r
                b.Lock()
            }
            SyncBar()
            SetStatus("Game window bound. Set/save client ROIs, then press Ctrl+Alt+F9 in the game to Resume.")
        } catch as e {
            GameSession.Bound := false
            SetStatus(e.Message)
        }
    }
    static Bounds() {
        WinGetClientPos(&x,&y,&w,&h,"ahk_id " GameSession.Hwnd)
        if w < 8 || h < 8
            throw Error("Game client is minimized or unavailable")
        return {x:x,y:y,w:w,h:h}
    }
    static IdentityOK(foreground := true) {
        if !GameSession.Enabled
            return true
        if !GameSession.Bound || !GameProfiles.Current
            return false
        try {
            id := GameSession.Identity(GameSession.Hwnd)
            if id.pid != GameSession.Pid || id.created != GameSession.Created || StrLower(id.exe) != StrLower(GameSession.Exe)
                return false
            if foreground && DllCall("GetForegroundWindow","ptr") != GameSession.Hwnd
                return false
            GameSession.Bounds()
            return true
        }
        return false
    }
    static Check(ticket := 0) {
        if !GameSession.Enabled
            return true
        if !GameSession.Armed
            return false
        if ticket && (ticket["epoch"] != GameSession.Epoch || ticket["token"] != GameSession.Token)
            return false
        if !GameSession.IdentityOK() {
            GameSession.Suspend("foreground-or-identity-changed")
            return false
        }
        if !GameSession.Direct() && !GameSession.LunaSelectionOK() {
            GameSession.Suspend("luna-selection-invalidated")
            return false
        }
        return true
    }
    static Resume(*) {
        global State, LunaState
        if !GameSession.Enabled
            return true
        if !GameSession.ForegroundHook {
            SetStatus("Foreground event guard is unavailable; reading stays stopped.")
            return false
        }
        if !GameSession.IdentityOK() {
            SetStatus("Resume requires the explicitly bound game window in the foreground.")
            return false
        }
        p := GameProfiles.Current
        if p["source"] != "ocr-boxes" && !GameProfiles.LunaPolicyAllowed(p) {
            SetStatus("Luna compatibility/source evidence is missing for this build.")
            return false
        }
        found := 0
        if p["source"] = "ocr-boxes"
            for b in Boxes
                if b && b.locked && GameSession.PrepareBox(b)
                    found += 1
        if p["source"] = "ocr-boxes" && !found {
            SetStatus("Lock a region inside the selected game's client before Resume.")
            return false
        }
        if GameSession.Armed || GameSession.FocusLost || Speaking || Pending.Length || Rdr.Total()
            GameSession.Suspend("resume-reset")
        if p["source"] != "ocr-boxes" {
            try GameSession.AcquireLuna()
            catch as err {
                SetStatus(err.Message)
                return false
            }
        }
        GameSession.Epoch += 1
        GameSession.Token := GameSession.Client "-" GameSession.Epoch "-" DllCall("GetTickCount64","uint64")
        GameSession.LunaSource := p["source"] = "ocr-boxes" ? "" : p["lunaSelection"]["source_session"]
        GameSession.LunaGeneration := p["source"] = "ocr-boxes" ? 0 : p["lunaSelection"]["source_generation"]
        GameSession.LunaSequence := 0
        Lanes[MaxBoxes+1].exact := p["source"] = "luna-hook"
        for lane in Lanes {
            lane.Clear()
            lane.lastNorm := ""
        }
        Spk.voice := p["protection"] = "unprotected-confirmed" ? p["voice"] : "af_heart"
        Spk.speed := p["speed"]
        GameSession.Armed := true
        State := "playing"
        if p["source"] != "ocr-boxes"
            LunaState := "waiting"
        SetStatus("Selected game session active. Alt+Tab stops and clears; Resume is explicit.")
        return true
    }
    static PrepareBox(b) {
        bounds := GameSession.Bounds()
        if !b.HasOwnProp("relativeROI") {
            r := Map("x",(b.rect.x-bounds.x)/bounds.w,"y",(b.rect.y-bounds.y)/bounds.h,
                     "w",b.rect.w/bounds.w,"h",b.rect.h/bounds.h)
            try GameProfiles.ValidateROI(r)
            catch
                return false
            b.relativeROI := r
        }
        r := b.relativeROI
        current := {x:bounds.x+Round(r["x"]*bounds.w),y:bounds.y+Round(r["y"]*bounds.h),
                    w:Round(r["w"]*bounds.w),h:Round(r["h"]*bounds.h)}
        if current.w < 8 || current.h < 8
            return false
        if b.rect.x != current.x || b.rect.y != current.y || b.rect.w != current.w || b.rect.h != current.h {
            b.gen := OcrBox.NextGen()
            b.haveRef := false
            b.tracker.Reset()
        }
        b.rect := current
        return true
    }
    static Ticket() {
        p := GameProfiles.Current
        return Map("expected_source_session",GameSession.LunaSource,"expected_source_generation",GameSession.LunaGeneration,
                   "client_id",GameSession.Client,"token",GameSession.Token,"epoch",GameSession.Epoch,
                   "pid",GameSession.Pid,"hwnd",GameSession.Hwnd,"created",GameSession.Created,
                   "source",p["source"],"protection",p["protection"],
                   "luna_permitted",GameJsonLiteral(GameProfiles.LunaAllowed(p) ? "true" : "false"),
                   "controlled_test",p.Get("controlledTest",Map()),"SteamAppID",p["SteamAppID"],"build",p["build"],
                   "exe",p["exe"],"exe_sha256",p.Get("exe_sha256",""),"luna_policy_sha256",p.Get("lunaPolicySha256",""))
    }
    static Direct() => !GameSession.Enabled || (GameProfiles.Current && GameProfiles.Current["source"] = "ocr-boxes")
    static Watch() {
        if GameSession.Armed
            GameSession.Check()
    }
    static Suspend(reason, clearBinding := false) {
        global State, QueueEpoch, LunaState
        if !GameSession.Enabled
            return
        p := GameProfiles.Current
        if p && (p.Get("lunaSelection",0) is Map) && p["lunaSelection"].Has("source_session")
            GameSession.LastLunaKey := p["lunaSelection"]["source_session"] ":" p["lunaSelection"]["source_generation"]
        if p
            p["lunaSelection"] := Map()
        GameSession.SelectionAfter := LunaReceipt.NowFileTime()
        wasActive := GameSession.Armed
        GameSession.Armed := false
        GameSession.FocusLost := false
        GameSession.Epoch += 1
        GameSession.Drops["invalidations"] += 1
        State := "stopped"
        QueueEpoch += 1
        CancelSpeech()
        CancelOcrJob()
        for item in Pending
            item.hbm := ""
        Pending.Length := 0
        for lane in Lanes {
            lane.Clear()
            lane.lastNorm := ""
        }
        for b in Boxes
            if b {
                b.gen := OcrBox.NextGen()
                b.haveRef := false
                b.tracker.Reset()
            }
        LunaState := "off"
        ; Stop is allowed after focus loss; this only invalidates our helper epoch.
        try {
            if Helper.lastAnswer != ""
                Http("POST",Helper.Url "/session/stop",'{"session":{"client_id":' JsonStr(GameSession.Client) ',"epoch":' GameSession.Epoch '}}',1000)
        }
        if clearBinding
            GameSession.Bound := false
        if wasActive
            SetStatus("Reading stopped (" reason "). Return to the game and Resume explicitly.")
    }
    static AcceptLuna(event, ticket) {
        if !GameSession.Check(ticket) || !(event is Map)
            return false
        p := GameProfiles.Current
        mode := p["source"] = "luna-hook" ? "hook" : "ocr"
        if event.Get("schema","") != "local-reader-origin-v1" || event.Get("source_mode","") != mode
            return false
        if event.Get("game_pid",0) != GameSession.Pid || event.Get("game_hwnd",0) != GameSession.Hwnd || event.Get("process_creation_filetime","") != GameSession.Created
            return false
        session := event.Get("source_session",""), generation := event.Get("source_generation",0), sequence := event.Get("sequence",0)
        if session = "" || !IsInteger(generation) || generation < 1 || !IsInteger(sequence) || sequence < 1
            return false
        if session != GameSession.LunaSource || generation != GameSession.LunaGeneration || sequence <= GameSession.LunaSequence
            return false
        GameSession.LunaSequence := sequence
        return true
    }
}





