#Requires AutoHotkey v2.0
; A private helper for this instance's explicit screen-area snapshots and playback.
class DesktopReader {
    static Url := ""
    static Token := ""
    static Root := ""
    static StartedAt := 0
    static Seq := 0
    static Init() {
        if DesktopReader.Root != ""
            return
        random := Buffer(32)
        if DllCall("bcrypt\BCryptGenRandom","ptr",0,"ptr",random,"uint",32,"uint",2,"uint")
            throw Error("Could not create the local reader identity.")
        token := ""
        Loop random.Size
            token .= Format("{:02x}",NumGet(random,A_Index-1,"uchar"))
        DesktopReader.Token := token
        DesktopReader.Root := EnvGet("LOCALAPPDATA") "\OcrBoxes\desktop-reader\" DllCall("GetCurrentProcessId") "-" SubStr(token,1,16)
        DirCreate(DesktopReader.Root)
        SnapshotFiles.Dir := DesktopReader.Root
    }
    static Ensure() {
        DesktopReader.Init()
        if DesktopReader.Url != "" {
            response := DesktopReader.Send("/health", "", 1200)
            return response.status = 200 && JsonField(response.text,"protocol") = "desktop-reader-v1" ? "ready" : "!The private desktop reader stopped responding. Restart OCR Boxes to reconnect."
        }
        ready := DesktopReader.Root "\ready.json"
        if FileExist(ready) {
            data := FileRead(ready,"UTF-8")
            port := JsonNumber(data,"port")
            if IsInteger(port) && port > 0 && port < 65536 && JsonNumber(data,"parent") = DllCall("GetCurrentProcessId") && JsonField(data,"protocol") = "desktop-reader-v1" {
                DesktopReader.Url := "http://127.0.0.1:" port
                return DesktopReader.Ensure()
            }
            return "!The desktop reader returned an invalid identity."
        }
        if DesktopReader.StartedAt
            return A_TickCount-DesktopReader.StartedAt < 20000 ? "starting" : "!The desktop reader did not start. Check its Python dependencies."
        script := A_ScriptDir "\..\rapidocr-helper\desktop_reader.py"
        python := Helper.PythonPath()
        if !FileExist(script) || !FileExist(python)
            return "!The desktop reader or its existing Python runtime is missing."
        bootstrap := DesktopReader.Root "\bootstrap.json"
        body := '{"parent":' DllCall("GetCurrentProcessId") ',"token":' JsonStr(DesktopReader.Token) ',"root":' JsonStr(DesktopReader.Root) ',"ready":' JsonStr(ready) '}'
        FileAppend(body,bootstrap,"UTF-8-RAW")
        try Run('"' python '" "' script '" --bootstrap "' bootstrap '"',,"Hide")
        catch as error
            return "!Could not start the desktop reader."
        DesktopReader.StartedAt := A_TickCount
        return "starting"
    }
    static Body(fields := "") => '{"token":' JsonStr(DesktopReader.Token) (fields != "" ? "," fields : "") '}'
    static Send(route, fields := "", wait := 1500) {
        if DesktopReader.Url = ""
            return {status:0,text:""}
        return Http("POST",DesktopReader.Url route,DesktopReader.Body(fields),wait)
    }
    static StopOcr() {
        if DesktopReader.Url != ""
            DesktopReader.Send("/ocr/stop",'"epoch":' QueueEpoch,1000)
    }
    static Cleanup() {
        for name in ["bootstrap.json","ready.json"]
            if DesktopReader.Root != ""
                try FileDelete(DesktopReader.Root "\" name)
        if DesktopReader.Root != ""
            try DirDelete(DesktopReader.Root) ; empty only; never recurse through user files
    }
}

class RoutedKokoroSpeaker extends KokoroSpeaker {
    Name := "Kokoro Player (Windows default output)"
    __New() {
        super.__New()
        this.lastCommand := 0
        this.over := true
    }
    Command(action, fields := "") {
        DesktopReader.Seq += 1
        this.lastCommand := DesktopReader.Seq
        response := DesktopReader.Send("/tts/" action,'"seq":' this.lastCommand (fields != "" ? "," fields : ""),2000)
        if response.status != 200
            throw Error("The private speech reader did not accept " action ".")
        return response
    }
    Start(text) {
        ready := DesktopReader.Ensure()
        if ready != "ready"
            throw Error(ready = "starting" ? "Starting the desktop speech reader..." : SubStr(ready,2))
        voice := this.voice
        if voice = "" {
            response := Http("GET",this.url "/settings","",1500)
            voice := response.status = 200 ? JsonField(response.text,"voice") : ""
        }
        if voice = ""
            throw Error("Choose a Kokoro Player voice before reading.")
        if SubStr(voice,1,3) = "qn_" && this.speed != 1
            throw Error("This narrator requires playback speed 1.00. Choose that speed or a Kokoro CPU voice.")
        this.Command("start",'"text":' JsonStr(text) ',"voice":' JsonStr(voice) ',"speed":' Format("{:.2f}",this.speed))
        this.over := false
        this.LastError := ""
        this.failures := 0
    }
    Busy() {
        if this.over
            return false
        response := DesktopReader.Send("/tts/status")
        if response.status != 200 {
            this.failures += 1
            if this.failures < 3
                return true
            this.LastError := "The desktop speech reader disconnected."
            this.over := true
            return false
        }
        this.failures := 0
        if JsonTrue(response.text,"speaking")
            return true
        this.LastError := JsonField(response.text,"error")
        this.over := true
        return false
    }
    Stop() {
        this.over := true
        if DesktopReader.Url != ""
            try this.Command("stop")
    }
    Pause() {
        if !this.over
            this.Command("pause")
    }
    Resume() {
        if !this.over
            this.Command("resume")
    }
}
