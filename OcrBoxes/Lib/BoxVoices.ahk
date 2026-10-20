#Requires AutoHotkey v2.0
; Provider-specific choices for future utterances. The selected player is never changed.
class BoxVoiceError extends Error {
}
class BoxVoices {
    static Ids := []
    static Engine := ""
    static Labels := []
    static AddControls() {
        if GameSession.Enabled || E2E
            return
        BarCtl.boxVoices := []
        Bar.Add("Text","xs y+8 w420","Voice for each box (player stays selected above)")
        BarCtl.boxVoiceHint := Bar.Add("Text","xs y+3 w420 r2","")
        Loop MaxBoxes {
            slot := A_Index
            Bar.Add("Text","xs y+8 w62","Box " slot)
            ctrl := Bar.Add("DropDownList","x+4 yp-3 w354",["Use default voice"])
            ctrl.OnEvent("Change",BoxVoices.Changed.Bind(slot))
            BarCtl.boxVoices.Push(ctrl)
        }
    }
    static Refresh() {
        if !BarCtl.HasOwnProp("boxVoices")
            return
        key := Cfg.Get("voice","engine","")
        BoxVoices.Engine := key
        BoxVoices.Ids := [""]
        BoxVoices.Labels := ["Use default voice"]
        if key = "kokoro" {
            labels := ControlGetItems(BarCtl.voice.Hwnd)
            for i,id in VoiceIds
                if id != "" {
                    BoxVoices.Ids.Push(id)
                    BoxVoices.Labels.Push(labels[i])
                }
        } else if key = "sapi" && Speakers.Has("sapi") {
            for name in Speakers["sapi"].Voices() {
                BoxVoices.Ids.Push(name)
                BoxVoices.Labels.Push(name)
            }
        } else if key = "edge" {
            for item in EdgeSpeaker.Allowed {
                BoxVoices.Ids.Push(item.id)
                BoxVoices.Labels.Push(item.label)
            }
        }
        BarCtl.boxVoiceHint.Text := (key = "browser" || key = "eleven") ? "This player manages one shared voice. Choose Kokoro or SAPI for separate box voices." : "Use default voice inherits the voice above. Changes apply to future readings."
        for slot,ctrl in BarCtl.boxVoices {
            ctrl.Delete()
            ctrl.Add(BoxVoices.Labels)
            saved := Cfg.Get("boxVoices",key "_" slot,"")
            pick := PositionOf(BoxVoices.Ids,saved)
            if !pick && saved != "" {
                ctrl.Add(["Unavailable saved voice: select another"])
                pick := BoxVoices.Ids.Length+1
            }
            ctrl.Choose(pick ? pick : 1)
            ctrl.Enabled := BoxVoices.Ids.Length > 1
        }
    }
    static Changed(slot,ctrl,*) {
        if GameSession.Enabled || BoxVoices.Engine != Cfg.Get("voice","engine","") || ctrl.Value > BoxVoices.Ids.Length
            return
        Cfg.Set("boxVoices",BoxVoices.Engine "_" slot,BoxVoices.Ids[ctrl.Value])
        SetStatus("Box " slot " voice saved for its next reading. The current sentence keeps its voice.")
    }
    static Apply(slot,speaker, test := false) {
        if GameSession.Enabled || E2E || (SelfTest && !test)
            return
        key := Cfg.Get("voice","engine","")
        choice := slot >= 1 && slot <= MaxBoxes ? Cfg.Get("boxVoices",key "_" slot,"") : ""
        if choice != "" && (key != BoxVoices.Engine || !PositionOf(BoxVoices.Ids,choice))
            throw BoxVoiceError("Box " slot " has an unavailable voice for the selected player. Choose another voice.")
        if key = "kokoro"
            speaker.voice := choice != "" ? choice : Cfg.Get("voice","kokoroVoice","")
        else if key = "sapi" {
            wanted := choice != "" ? choice : Cfg.Get("voice","sapiVoice","")
            if !speaker.SetVoice(wanted)
                throw BoxVoiceError("Choose an installed allowed SAPI voice for Box " slot ".")
        } else if key = "edge" {
            if !speaker.SetVoice(choice != "" ? choice : Cfg.Get("voice","edgeVoice","ava"))
                throw BoxVoiceError("Choose an available Edge voice for Box " slot ".")
        } else if choice != ""
            throw BoxVoiceError("This player manages its own voice. Choose a player with selectable voices to assign box voices.")
    }
}
ApplyReaderTheme() {
    Bar.BackColor := "0C0C0E"
    dark := 1
    try DllCall("dwmapi\DwmSetWindowAttribute","ptr",Bar.Hwnd,"int",20,"int*",&dark,"int",4)
    for ctrl in Bar {
        if ctrl.Type = "Text" || ctrl.Type = "CheckBox"
            ctrl.SetFont("cF4EDE3")
        if ctrl.Type = "DropDownList" {
            try ctrl.Opt("cF4EDE3 Background161618")
            try DllCall("uxtheme\SetWindowTheme","ptr",ctrl.Hwnd,"str","DarkMode_CFD","ptr",0)
        }
        if ctrl.Type = "Button"
            try DllCall("uxtheme\SetWindowTheme","ptr",ctrl.Hwnd,"str","DarkMode_Explorer","ptr",0)
    }
}
