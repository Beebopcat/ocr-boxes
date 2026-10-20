#Requires AutoHotkey v2.0
; BoxState.ahk - tells the Desktop Pixel Companions app whether OCR Boxes is speaking, so the avatars can animate while it reads.
; The file holds one word ("speaking" or "idle") and never any text.
class BoxState {
    static Dir := Cfg.Get("runtime","stateDir",EnvGet("LOCALAPPDATA") "\OcrBoxes")
    static Path := BoxState.Dir "\state.txt"
    static Last := ""
    static Set(state) {
        if state = BoxState.Last
            return
        BoxState.Last := state
        try {
            DirCreate(BoxState.Dir)
            f := FileOpen(BoxState.Path, "w", "UTF-8-RAW")
            f.Write(state)
            f.Close()
        }
    }
}

