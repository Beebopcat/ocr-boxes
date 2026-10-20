class PerBoxSilentSpeaker {
    Name := "silent box voice test"
    LastError := ""
    voice := ""
    Calls := []
    IsBusy := false
    Voices() => [{id:"af_heart",label:"Heart (test)"},{id:"bf_emma",label:"Emma (test)"}]
    Start(text) => this.Calls.Push({text:text,voice:this.voice})
    Busy() => this.IsBusy
    Stop() => 0
    Pause() => 0
    Resume() => 0
}
RunBoxVoiceTests() {
    global Spk, Speakers, VoiceKeys, VoiceLabels, OcrKeys, State, Results, Bar, VoiceIds, SelfTest, Speaking, RetryAt, Rdr, Lanes
    out := A_Args[2]
    PrepareTestStorage(out)
    OnError(OnTestError)
    Cfg.Ensure()
    GameSession.Enabled := false
    State := "stopped"
    Cfg.Set("voice","engine","kokoro")
    Cfg.Set("voice","kokoroVoice","af_heart")
    Cfg.Set("ocr","engine","rapid")
    Cfg.Set("bar","x",-1800)
    Cfg.Set("bar","y",0)
    Spk := PerBoxSilentSpeaker()
    Speakers := Map("kokoro",Spk)
    VoiceKeys := ["kokoro"]
    VoiceLabels := ["Kokoro Player (default output)"]
    OcrKeys := ["windows","rapid"]
    BuildBar()
    T("four independent voice selectors exist",BarCtl.boxVoices.Length = 4)
    T("bar uses Kokoro charcoal background",Bar.BackColor = "0C0C0E")
    T("per-box choices use selected provider catalogue",BoxVoices.Ids.Length = 3 && BoxVoices.Ids[2] = "af_heart" && BoxVoices.Ids[3] = "bf_emma")
    BarCtl.boxVoices[1].Choose(3)
    BoxVoices.Changed(1,BarCtl.boxVoices[1])
    BarCtl.boxVoices[2].Choose(2)
    BoxVoices.Changed(2,BarCtl.boxVoices[2])
    T("box voice change preserves player",Cfg.Get("voice","engine","") = "kokoro" && Spk is PerBoxSilentSpeaker)
    BoxVoices.Apply(1,Spk,true)
    Spk.Start("first")
    BoxVoices.Apply(2,Spk,true)
    Spk.Start("second")
    T("each box dispatches its own voice",Spk.Calls[1].voice = "bf_emma" && Spk.Calls[2].voice = "af_heart")
    Cfg.Set("boxVoices","kokoro_1","af_heart")
    T("changing next voice does not retarget dispatched utterance",Spk.Calls[1].voice = "bf_emma")
    BoxVoices.Apply(3,Spk,true)
    T("unset box inherits selected default voice",Spk.voice = "af_heart")
    Cfg.Set("boxVoices","kokoro_4","missing")
    rejected := false
    try BoxVoices.Apply(4,Spk,true)
    catch BoxVoiceError
        rejected := true
    T("missing voice fails without silent substitution",rejected && Spk.voice = "af_heart")
    Cfg.Set("boxVoices","sapi_1","separate")
    BoxVoices.Apply(1,Spk,true)
    T("voice settings are isolated per provider",Spk.voice = "af_heart")
    GameSession.Enabled := true
    Spk.voice := "guarded"
    BoxVoices.Apply(1,Spk,true)
    T("guarded game policy bypasses per-box overrides",Spk.voice = "guarded")
    GameSession.Enabled := false
    Cfg.Set("boxVoices","kokoro_1","bf_emma")
    Cfg.Set("boxVoices","kokoro_2","af_heart")
    Lanes := []
    Loop MaxBoxes
        Lanes.Push(Lane("Box " A_Index))
    Rdr := Reader(Lanes)
    Lanes[1].Offer("First queued reading.",A_TickCount)
    Lanes[2].Offer("Second queued reading.",A_TickCount)
    Spk.Calls := []
    Spk.IsBusy := true
    Speaking := false
    RetryAt := 0
    State := "playing"
    SelfTest := false
    try {
        PumpSpeechCore()
        Cfg.Set("boxVoices","kokoro_1","af_heart")
        PumpSpeechCore()
        T("busy queue preserves the active box voice",Spk.Calls.Length = 1 && Spk.Calls[1].voice = "bf_emma" && Spk.voice = "bf_emma")
        Spk.IsBusy := false
        PumpSpeechCore()
        T("real queue dispatches next lane voice without player change",Spk.Calls.Length = 2 && Spk.Calls[2].voice = "af_heart" && Cfg.Get("voice","engine","") = "kokoro")
    } finally {
        SelfTest := true
        State := "stopped"
        Speaking := false
    }
    Loop 2 {
        pass := A_Index
        Loop MonitorGetCount() {
            index := A_Index
            MonitorGetWorkArea(index,&left,&top,&right,&bottom)
            WinMove(left+30,top+30,,,"ahk_id " Bar.Hwnd)
            Sleep 350
            FitBarToDisplay()
            WinGetClientPos(&cx,&cy,&cw,&ch,"ahk_id " Bar.Hwnd)
            WinGetPos(&wx,&wy,&ww,&wh,"ahk_id " Bar.Hwnd)
            fits := true
            for ctrl in Bar {
                WinGetPos(&x,&y,&w,&h,"ahk_id " ctrl.Hwnd)
                if x < cx || y < cy || x+w > cx+cw+1 || y+h > cy+ch+1
                    fits := false
            }
            T("full voice UI fits display " index " pass " pass,fits && wx >= left && wy >= top && wx+ww <= right && wy+wh <= bottom,"size=" ww "x" wh)
        }
    }
    Bar.Destroy()
    Bar := 0
    FileAppend(Results,out,"UTF-8")
    ExitApp(InStr(Results,"FAIL ") ? 1 : 0)
}
RunBoxVoiceTests()
