#Requires AutoHotkey v2.0
; ============================================================================
;  Speakers.ahk - the four ways OCR Boxes can speak.  All four have the same small interface so the reader never cares which is in use:
;      Start(text)   begin speaking and return at once (throws an Error with a plain-language message if it cannot)
;      Busy()        true until that utterance has finished
;      Stop()        cut the current utterance off
;      Pause() / Resume()   only SAPI can freeze the sentence it is in; the others hold the queue at the next sentence
;      LastError     the last problem, for the status line
; ============================================================================

; ---- Windows SAPI: the route for Microsoft Edge's natural ("Online (Natural)") voices ----------------------------------------
; Edge's and Narrator's natural voices are not offered to other programs by Windows itself.  The open-source NaturalVoiceSAPIAdapter
; (github.com/gexgd0419/NaturalVoiceSAPIAdapter) registers them as ordinary SAPI 5 voices (see docs/third-party/natural-voice-sapi-adapter-review.md
; before installing it).
;
; VOICE RULE (owner, 2026-10-10): the ONLY SAPI voices this program lists, selects or speaks with are the three Edge voices below.  The classic
; Windows voices - Microsoft David, Hazel, George, Zira and Susan - are excluded everywhere: they are never listed, never chosen as a default, a saved
; setting that names one is ignored, and Start() refuses to speak when no allowed voice has been chosen (SAPI's own default voice is one of them).
class SapiSpeaker {
    Name := "Edge natural voices (SAPI)"
    LastError := ""
    static Allowed := ["Microsoft Ava Multilingual Online (Natural)", "Microsoft Brian Multilingual Online (Natural)", "Microsoft Ryan Online (Natural)"]
    static Excluded := ["David", "Hazel", "George", "Zira", "Susan"]
    ; The part of a voice description before " - <language>" must be one of the three (so plain "Ava Online" is NOT "Ava Multilingual Online").
    static IsAllowed(name) {
        base := Trim(InStr(name, " - ") ? SubStr(name, 1, InStr(name, " - ") - 1) : name)
        for want in SapiSpeaker.Allowed
            if StrLower(base) = StrLower(want)
                return true
        return false
    }
    ; True for the classic Windows voices that must never be used (belt and braces: IsAllowed already refuses them).
    static IsExcluded(name) {
        for word in SapiSpeaker.Excluded
            if RegExMatch(name, "i)\bMicrosoft\s+" word "\b")
                return true
        return false
    }
    __New() {
        this.v := ComObject("SAPI.SpVoice")
        this.startTick := 0
        this.paused := false
        this.chosen := ""                                         ; the allowed voice in use; "" = none, and then nothing is spoken
    }
    ; Every installed voice token.  SpVoice.GetVoices() fails with 0x80045039 on some PCs (it did on the owner's), but enumerating the
    ; voice category directly always works, so that is tried first.
    Tokens() {
        try {
            cat := ComObject("SAPI.SpObjectTokenCategory")
            cat.SetId("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech\Voices", false)
            return cat.EnumerateTokens("", "")
        }
        return this.v.GetVoices()
    }
    ; Names of the installed SAPI voices that are allowed (see the voice rule above); an empty list when none of the three is installed.
    Voices() {
        list := []
        tokens := this.Tokens()
        Loop tokens.Count {
            name := tokens.Item(A_Index - 1).GetDescription()
            if SapiSpeaker.IsAllowed(name) && !SapiSpeaker.IsExcluded(name)
                list.Push(name)
        }
        return list
    }
    ; Selects an allowed voice; refuses (returns false, nothing changes) for any other name, including a stale setting that names an excluded voice.
    SetVoice(name) {
        if !SapiSpeaker.IsAllowed(name) || SapiSpeaker.IsExcluded(name)
            return false
        tokens := this.Tokens()
        Loop tokens.Count {
            tok := tokens.Item(A_Index - 1)
            if tok.GetDescription() = name {
                this.v.Voice := tok
                this.chosen := name
                return true
            }
        }
        return false
    }
    SetRate(rate) {
        this.v.Rate := Min(Max(Integer(rate), -10), 10)
    }
    Start(text) {
        if this.chosen = "" {
            this.LastError := "No allowed SAPI voice is chosen: only Edge's Ava Multilingual, Brian Multilingual and Ryan (UK) are used, and none is installed."
            throw Error(this.LastError)
        }
        this.startTick := A_TickCount
        this.paused := false
        try this.v.Resume()                                       ; a Pause() from an earlier sentence would otherwise swallow this one
        this.v.Speak(text, 17)                                    ; SVSFlagsAsync | SVSFIsNotXML: OCR text is literal
    }
    Busy() {
        if A_TickCount - this.startTick < 150
            return true
        if this.paused
            return true
        return !this.v.WaitUntilDone(0)
    }
    ; Milliseconds from Start until the engine reported that it is speaking (the nearest thing SAPI offers to "first audio").
    SpeakingAfterMs() {
        try {
            if this.v.Status.RunningState = 2
                return A_TickCount - this.startTick
        }
        return -1
    }
    Stop() {
        try this.v.Resume()
        try this.v.Speak("", 3)                                   ; SVSFlagsAsync | SVSFPurgeBeforeSpeak
        this.paused := false
    }
    Pause() {
        try this.v.Pause()
        this.paused := true
    }
    Resume() {
        try this.v.Resume()
        this.paused := false
    }
}

; ---- Kokoro Player (the local voice service on 127.0.0.1:8787) ---------------------------------------------------------------
class KokoroSpeaker {
    Name := "Kokoro Player"
    LastError := ""
    __New(request := 0) {
        this.request := request ? request : Http
        this.generation := 0
        this.commandSeq := 0
        this.clientId := "ocrboxes-" DllCall("GetCurrentProcessId") "-" DllCall("GetTickCount64","uint64")
        this.SessionCheck := 0
        this.starting := false
        this.paused := false
        this.loadingPaused := false
        this.playbackGeneration := 0
        this.url := Cfg.Get("kokoro", "url", "http://127.0.0.1:8787")
        this.voice := ""
        this.speed := 1.0
        this.startTick := 0
        this.seenBusy := false
        this.failures := 0
        this.over := false
    }
    Voices() {
        r := this.request.Call("GET", this.url "/voices", "", 4000)
        list := []
        if r.status = 200 {
            pos := 1
            while pos := RegExMatch(r.text, '"id"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"label"\s*:\s*"((?:[^"\\]|\\.)*)"', &m, pos) {
                list.Push({id: JsonUnstr(m[1]), label: JsonUnstr(m[2])})
                pos += m.Len
            }
        }
        return list
    }
    CheckSession() {
        if this.SessionCheck && !this.SessionCheck.Call()
            throw Error("Game speech session was cancelled")
    }
    Start(text) {
        this.CheckSession()
        this.generation += 1
        generation := this.generation
        this.starting := true
        try {
            this.commandSeq += 1
            body := '{"client_id":' JsonStr(this.clientId) ',"command_seq":' this.commandSeq ',"text":' JsonStr(text)
            if this.voice != ""
                body .= ',"voice":' JsonStr(this.voice)
            body .= ',"speed":' Format("{:.2f}",this.speed) "}"
            this.CheckSession()
            r := this.request.Call("POST",this.url "/speak",body,8000)
            tries := 0
            while r.status = 503 && tries < 10 {
                Sleep 500
                if generation != this.generation
                    throw Error("Kokoro start cancelled")
                this.CheckSession()
                r := this.request.Call("POST",this.url "/speak",body,8000)
                tries += 1
            }
            if generation != this.generation
                throw Error("Kokoro start cancelled")
            this.CheckSession()
            if r.status < 200 || r.status >= 300 {
                this.LastError := r.status = 0 ? "Kokoro Player is not running." : "Kokoro Player did not accept the reading."
                throw Error(this.LastError)
            }
            action := JsonField(r.text,"action")
            if action = "superseded" || action = "not-owner"
                throw Error("Kokoro start was superseded")
            this.playbackGeneration := JsonNumber(r.text,"generation")
            this.LastError := ""
            this.startTick := A_TickCount
            this.seenBusy := false
            this.failures := 0
            this.over := false
            this.paused := false
            this.loadingPaused := false
        } finally {
            this.starting := false
        }
    }
    ; The player says "idle" when it is not speaking.  Once it has been seen busy, idle again means this sentence is over.
    Busy() {
        if this.paused && !this.over
            return true
        if this.over
            return false
        elapsed := A_TickCount - this.startTick
        if elapsed < 200
            return true
        if elapsed > 180000 {
            this.over := true
            return false
        }
        r := this.request.Call("GET", this.url "/health", "", 1500)
        if r.status != 200 {
            this.failures += 1
            if this.failures >= 3 {
                this.over := true
                return false
            }
            return true
        }
        this.failures := 0
        state := StrLower(JsonField(r.text, "state"))
        if state != "" && state != "idle" && state != "ready" && state != "stopped" && state != "done" {
            this.seenBusy := true
            return true
        }
        if !this.seenBusy && elapsed < 2500
            return true                                           ; it has not picked the sentence up yet
        this.over := true
        return false
    }
    Control(action, includeGeneration := true) {
        this.commandSeq += 1
        body := '{"client_id":' JsonStr(this.clientId) ',"command_seq":' this.commandSeq ',"owner_only":true'
        if includeGeneration && IsNumber(this.playbackGeneration) && this.playbackGeneration > 0
            body .= ',"expected_generation":' this.playbackGeneration
        body .= "}"
        r := this.request.Call("POST",this.url "/" action,body,3000)
        if r.status < 200 || r.status >= 300
            throw Error("Kokoro " action " did not complete")
        return r
    }
    Stop() {
        this.generation += 1
        this.over := true
        this.paused := false
        this.loadingPaused := false
        try this.Control("stop",false) ; owner-only Stop still records a barrier against delayed Start
        this.over := true
    }
    Pause() {
        ; A loading Start must not become audible after Pause. Cancel it, retain its
        ; FIFO line in PumpSpeechCore, and let Play retry that line from the start.
        if this.starting {
            this.Stop()
            this.loadingPaused := true
            this.paused := true
            return
        }
        this.generation += 1
        this.Control("pause")
        this.paused := true
    }
    Resume() {
        this.CheckSession()
        if this.loadingPaused {
            this.loadingPaused := false
            this.paused := false
            return ; the cancelled loading line remains in the reader FIFO
        }
        this.Control("resume")
        this.startTick := A_TickCount
        this.paused := false
    }
}

; ---- Edge natural voices, online, through the RapidOCR helper (no DLL, no registry, no administrator) ---------------------------
; The helper (rapidocr-helper/edge_tts.py) talks to the same service Edge's Read Aloud uses, over a TLS connection whose certificate and host name are
; verified, and it can only ask for the three voices below.  Nothing is loaded into other programs.  The spoken text goes to Microsoft's servers, so an internet
; connection is needed; the service is unofficial and can change.  This is what replaced the NaturalVoiceSAPIAdapter route (see the review in docs/third-party).
class EdgeSpeaker {
    Name := "Edge natural voices (online)"
    LastError := ""
    static Allowed := [{id: "ava", label: "Microsoft Ava Multilingual Online (Natural) - English (United States)"}
                     , {id: "brian", label: "Microsoft Brian Multilingual Online (Natural) - English (United States)"}
                     , {id: "ryan", label: "Microsoft Ryan Online (Natural) - English (United Kingdom)"}]
    static IsAllowedId(id) {
        for v in EdgeSpeaker.Allowed
            if StrLower(Trim(id)) = v.id
                return true
        return false
    }
    __New(request := 0) {
        this.request := request ? request : Http
        this.voice := "ava"
        this.rate := 0
        this.startTick := 0
        this.over := false
    }
    Voices() {
        list := []
        for v in EdgeSpeaker.Allowed
            list.Push(v.label)
        return list
    }
    ; false (and no change) for anything but ava / brian / ryan - the classic Windows voices can never be chosen.
    SetVoice(id) {
        if !EdgeSpeaker.IsAllowedId(id)
            return false
        this.voice := StrLower(Trim(id))
        return true
    }
    Start(text) {
        if !EdgeSpeaker.IsAllowedId(this.voice) {
            this.LastError := "Choose Ava, Brian or Ryan (UK) as the Edge voice."
            throw Error(this.LastError)
        }
        state := Helper.Ensure()
        if state != "ready" {
            if SubStr(state, 1, 1) = "!"
                this.LastError := SubStr(state, 2)
            else
                this.LastError := "The RapidOCR helper is still starting."
            throw Error(this.LastError)
        }
        body := '{"text":' JsonStr(text) ',"voice":' JsonStr(this.voice) ',"rate":' Integer(this.rate) '}'
        r := this.request.Call("POST", Helper.Url "/tts/edge", body, 8000)
        if r.status = 404 {
            this.LastError := "The running RapidOCR helper is older than the Edge voices. Close it (OCR Boxes starts its own) or set [helper] url to another port."
            throw Error(this.LastError)
        }
        if r.status != 200 {
            this.LastError := "Edge voice: " . Nz(JsonField(r.text, "error"), "HTTP " . r.status)
            throw Error(this.LastError)
        }
        this.LastError := ""
        this.startTick := A_TickCount
        this.over := false
    }
    ; The helper says "speaking" from the request until the last sound has played; an error from the service is reported once, then the line is over.
    Busy() {
        if this.over
            return false
        if A_TickCount - this.startTick < 200
            return true
        r := this.request.Call("GET", Helper.Url "/tts/edge/status", "", 1500)
        if r.status != 200 {
            this.over := true
            return false
        }
        if JsonTrue(r.text, "speaking")
            return true
        err := JsonField(r.text, "error")
        if err != ""
            this.LastError := "Edge voice: " err
        this.over := true
        return false
    }
    Stop() {
        try this.request.Call("POST", Helper.Url "/tts/edge/stop", "{}", 2000)
        this.over := true
    }
    ; The set-up of the connection to Microsoft's servers takes about 0.3 s: ask the helper to do it now, in the background (it answers at once).
    Warm() {
        if Helper.Ensure() != "ready"
            return
        try this.request.Call("POST", Helper.Url "/tts/edge/warm", "{}", 1500)
    }
    Pause() {
    }
    Resume() {
    }
}

; ---- ElevenLabs (cloud; the helper makes the call so the API key never passes through this script) ------------------------------
class ElevenSpeaker {
    Name := "ElevenLabs (cloud)"
    LastError := ""
    __New() {
        this.startTick := 0
        this.over := false
    }
    Start(text) {
        state := Helper.Ensure()
        if state != "ready" {
            if SubStr(state, 1, 1) = "!"
                this.LastError := SubStr(state, 2)
            else
                this.LastError := "The RapidOCR helper is still starting."
            throw Error(this.LastError)
        }
        voice := Cfg.Get("eleven", "voiceId", "")
        if voice = "" {
            this.LastError := "Enter your ElevenLabs voice id in OCR Boxes.ini ([eleven] voiceId)."
            throw Error(this.LastError)
        }
        body := '{"text":' JsonStr(text) ',"voice":' JsonStr(voice) ',"model":' JsonStr(Cfg.Get("eleven", "model", "eleven_flash_v2_5")) '}'
        r := Http("POST", Helper.Url "/tts/elevenlabs", body, 8000)
        if r.status != 200 {
            this.LastError := "ElevenLabs: " . Nz(JsonField(r.text, "error"), "HTTP " . r.status)
            throw Error(this.LastError)
        }
        this.LastError := ""
        this.startTick := A_TickCount
        this.over := false
    }
    Busy() {
        if this.over
            return false
        if A_TickCount - this.startTick < 200
            return true
        r := Http("GET", Helper.Url "/tts/status", "", 1500)
        if r.status != 200 {
            this.over := true
            return false
        }
        if JsonTrue(r.text, "speaking")
            return true
        err := JsonField(r.text, "error")
        if err != ""
            this.LastError := err
        this.over := true
        return false
    }
    Stop() {
        try Http("POST", Helper.Url "/tts/stop", "{}", 2000)
        this.over := true
    }
    Pause() {
    }
    Resume() {
    }
}



