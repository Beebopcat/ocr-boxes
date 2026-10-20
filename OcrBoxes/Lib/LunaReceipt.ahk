#Requires AutoHotkey v2.0
; Fixed owner-local handoff. A receipt is provenance, not same-user adversary authentication.
class LunaReceipt {
    static FixedPath := "C:\AI_Workspace\tools\LunaTranslator\LunaTranslator_x64\userconfig\local-reader-runtime\selection.json"
    static UserSid := ""
    static NowFileTime() {
        value := Buffer(8)
        DllCall("GetSystemTimePreciseAsFileTime","ptr",value)
        return NumGet(value,0,"uint64")
    }
    static UtcFileTime(value) {
        if Type(value) != "String" || !RegExMatch(value,"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?Z$",&m)
            throw Error("Receipt selection time must be UTC ISO")
        st := Buffer(16,0), ft := Buffer(8)
        for pair in [[0,1],[2,2],[6,3],[8,4],[10,5],[12,6]]
            NumPut("ushort",Integer(m[pair[2]]),st,pair[1])
        if !DllCall("SystemTimeToFileTime","ptr",st,"ptr",ft,"int")
            throw Error("Invalid receipt UTC selection time")
        fraction := m[7] = "" ? 0 : Integer(SubStr(m[7] "0000000",1,7))
        return NumGet(ft,0,"uint64") + fraction
    }
    static EvidenceKey(values) {
        if !(values is Array) || !values.Length || values.Length > 64
            throw Error("Missing reviewed evidence IDs")
        seen := Map(), text := ""
        for value in values {
            if Type(value) != "String" || !RegExMatch(value,"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$") || seen.Has(value)
                throw Error("Invalid or duplicate evidence ID")
            seen[value] := true
            text .= value "`n"
        }
        return Sort(text,"C")
    }
    static ControlledTestOK(p,now := 0,policyReader := 0) {
        try {
            if p.Get("source","") != "luna-hook" || p.Get("protection","") != "controlled-test-reviewed"
                || p.Get("validation","") != "APPROVED_FOR_CONTROLLED_TEST"
                || p.Get("lunaCompatibility","") != "APPROVED_FOR_CONTROLLED_TEST"
                || p.Get("lunaIsolation","") != "APPROVED_FOR_CONTROLLED_TEST"
                || p.Get("runtimeAcceptance","") != "UNTESTED" || p.Get("voice","") != "af_heart"
                return false
            lease := p.Get("controlledTest",0)
            if !(lease is Map) || lease.Count != 11
                return false
            expected := Map("schema","local-reader-controlled-test-v1","status","APPROVED_FOR_CONTROLLED_TEST",
                "runtimeAcceptance","UNTESTED","SteamAppID","1155970","build","15638588",
                "exe","C:\Program Files (x86)\Steam\steamapps\common\Roadwarden\Roadwarden.exe",
                "exe_sha256","EB0DA2D79E7466D1A3D2D306729F0925436102DAC168AC8B6A2E62EF4C29572B","source_mode","hook")
            for key,value in expected
                if Type(lease.Get(key,0)) != "String" || lease[key] != value
                    return false
            for key in ["SteamAppID","build","exe","exe_sha256"]
                if p.Get(key,"") != lease[key]
                    return false
            evidence := ["ROADWARDEN-SP-ENGINE-20261014","LUNAHOOK-RENPY-PY27-10.17.1.12","ROADWARDEN-BUILD-15638588-EXE-X64"]
            if LunaReceipt.EvidenceKey(lease.Get("evidenceIDs",[])) != LunaReceipt.EvidenceKey(evidence)
                || LunaReceipt.EvidenceKey(p.Get("lunaEvidenceIDs",[])) != LunaReceipt.EvidenceKey(evidence)
                || !(p.Get("lunaEvidence",0) is Array) || !p["lunaEvidence"].Length
                || StrLower(p.Get("lunaReceiptPath","")) != StrLower(LunaReceipt.FixedPath)
                || !RegExMatch(p.Get("lunaPolicySha256",""),"^[A-F0-9]{64}$")
                return false
            for key in ["issuedUtc","expiresUtc"]
                if Type(lease.Get(key,0)) != "String" || !RegExMatch(lease[key],"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
                    return false
            start := LunaReceipt.UtcFileTime(lease["issuedUtc"]), finish := LunaReceipt.UtcFileTime(lease["expiresUtc"])
            now := now ? now : LunaReceipt.NowFileTime()
            if start > now || now >= finish || finish <= start || finish-start > 288000000000
                return false
            if policyReader {
                policy := policyReader.Call()
            } else {
                path := "C:\AI_Workspace\tools\LunaTranslator\LunaTranslator_x64\userconfig\local-reader-policy.json"
                LunaReceipt.NoReparse(path)
                file := FileOpen(path,"r-w","UTF-8")
                try {
                    if file.Length < 1 || file.Length > 16384
                        return false
                    text := file.Read(16385)
                    if StrLen(text) > 16384
                        return false
                } finally file.Close()
                if LunaReceipt.HashFile(path) != p["lunaPolicySha256"]
                    return false
                policy := GameJson.Load(text)
            }
            if !(policy is Map) || policy.Count != 5 || policy.Get("schemaVersion",0) != 1
                || policy.Get("mode","") != "manual-hook-extraction"
                || !(policy.Get("approvedExecutables",0) is Array) || policy["approvedExecutables"].Length != 1
                || policy["approvedExecutables"][1] != lease["exe"]
                || !(policy.Get("approvedGames",0) is Array) || policy["approvedGames"].Length != 1
                || GameJson.Dump(policy.Get("controlledTest",Map())) != GameJson.Dump(lease)
                return false
            game := policy["approvedGames"][1]
            if !(game is Map) || game.Count != 5
                return false
            for key in ["SteamAppID","build","exe","exe_sha256"]
                if game.Get(key,"") != lease[key]
                    return false
            return LunaReceipt.EvidenceKey(game.Get("evidenceIDs",[])) = LunaReceipt.EvidenceKey(evidence)
        }
        return false
    }

    static PolicyOK(p,now := 0,policyReader := 0) {
        try {
            if LunaReceipt.ControlledTestOK(p,now,policyReader)
                return true
            return (p["source"] = "luna-ocr" || p["source"] = "luna-hook") && p["validation"] = "VERIFIED"
                && p.Get("lunaCompatibility","") = "VERIFIED" && p.Get("lunaIsolation","") = "VERIFIED"
                && p.Get("lastVerifiedBuild","") = p["build"]
                && p.Get("lunaEvidence",[]) is Array && p["lunaEvidence"].Length > 0
                && Type(p.Get("exe_sha256",0)) = "String" && RegExMatch(p["exe_sha256"],"^[0-9A-F]{64}$")
                && Type(p.Get("lunaPolicySha256",0)) = "String" && RegExMatch(p["lunaPolicySha256"],"^[0-9A-F]{64}$")
                && StrLower(p.Get("lunaReceiptPath","")) = StrLower(LunaReceipt.FixedPath)
                && LunaReceipt.EvidenceKey(p.Get("lunaEvidenceIDs",[])) != ""
                && p.Get("exe","") != ""
                && (p["source"] = "luna-ocr" || p["protection"] = "unprotected-confirmed")
        }
        return false
    }
    static Validate(receipt,p,id,actualHash,minimumTime := 0,now := 0,policyReader := 0) {
        if !LunaReceipt.PolicyOK(p,now,policyReader)
            throw Error("Current profile has no reviewed Luna policy")
        if !(receipt is Map) || receipt.Get("receiptSchema","") != "local-reader-selection-v1"
            throw Error("Unknown Luna selection schema")
        active := receipt.Get("active",0)
        if !(active is GameJsonLiteral) || active.value != "true"
            throw Error("Luna source selection is inactive")
        fields := ["receiptSchema","active","selectedUtc","SteamAppID","build","exe","exe_sha256","source_mode",
            "game_pid","game_hwnd","process_creation_filetime","source_session","source_generation","evidenceIDs","policySha256"]
        if receipt.Count != fields.Length
            throw Error("Unexpected Luna receipt fields")
        for key in fields
            if !receipt.Has(key)
                throw Error("Missing Luna receipt field")
        for key in ["SteamAppID","build"]
            if Type(receipt[key]) != "String" || !RegExMatch(receipt[key],"^\d+$") || receipt[key] != p[key]
                throw Error("Luna receipt game/build mismatch")
        if Type(receipt["exe"]) != "String" || StrLower(receipt["exe"]) != StrLower(id.exe) || StrLower(id.exe) != StrLower(p["exe"])
            throw Error("Luna receipt executable mismatch")
        if Type(receipt["exe_sha256"]) != "String" || !RegExMatch(receipt["exe_sha256"],"^[0-9A-F]{64}$")
            || receipt["exe_sha256"] != p["exe_sha256"] || receipt["exe_sha256"] != actualHash
            throw Error("Luna executable SHA256 does not match current reviewed file")
        if receipt["source_mode"] != (p["source"] = "luna-hook" ? "hook" : "ocr")
            throw Error("Luna receipt mode mismatch")
        for pair in [["game_pid",id.pid],["game_hwnd",id.hwnd]]
            if Type(receipt[pair[1]]) != "Integer" || receipt[pair[1]] <= 0 || receipt[pair[1]] != pair[2]
                throw Error("Luna receipt PID/HWND mismatch")
        if Type(receipt["process_creation_filetime"]) != "String" || !RegExMatch(receipt["process_creation_filetime"],"^[1-9]\d{0,19}$")
            || receipt["process_creation_filetime"] != id.created
            throw Error("Luna receipt process creation mismatch")
        if Type(receipt["source_session"]) != "String" || !RegExMatch(receipt["source_session"],"i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
            || Type(receipt["source_generation"]) != "Integer" || receipt["source_generation"] <= 0
            throw Error("Invalid Luna source epoch")
        if Type(receipt["policySha256"]) != "String" || receipt["policySha256"] != p["lunaPolicySha256"]
            || LunaReceipt.EvidenceKey(receipt["evidenceIDs"]) != LunaReceipt.EvidenceKey(p["lunaEvidenceIDs"])
            throw Error("Luna receipt policy/evidence scope mismatch")
        selectedTime := LunaReceipt.UtcFileTime(receipt["selectedUtc"])
        if minimumTime {
            now := now ? now : LunaReceipt.NowFileTime()
            if selectedTime < minimumTime || selectedTime > now + 50000000 || now-selectedTime > 1200000000
                throw Error("Bind/re-arm Luna in the selected game, then Resume within two minutes")
        }
        owned := Map()
        for key in fields
            owned[key] := GameJson.Load(GameJson.Dump(receipt[key]))
        return owned
    }
    static Acquire(p,id,minimumTime,previousKey := "",reader := 0,hasher := 0,now := 0) {
        actualHash := hasher ? hasher.Call(id.exe) : LunaReceipt.HashFile(id.exe)
        receipt := reader ? reader.Call(p) : LunaReceipt.Read(p)
        selected := LunaReceipt.Validate(receipt,p,id,actualHash,minimumTime,now)
        if selected["source_session"] ":" selected["source_generation"] = previousKey
            throw Error("A fresh explicit Luna Bind/re-arm is required after invalidation")
        return selected
    }
    static OpenSnapshot(p) {
        if StrLower(p.Get("lunaReceiptPath","")) != StrLower(LunaReceipt.FixedPath)
            throw Error("Luna receipt path is outside the fixed handoff")
        path := LunaReceipt.FixedPath
        LunaReceipt.NoReparse(path)
        SplitPath(path,,&parent)
        LunaReceipt.PrivateSecurity(parent,true)
        ; Deny in-place writers but permit FILE_SHARE_DELETE for producer os.replace.
        file := FileOpen(path,"r-w")
        try {
            if DllCall("GetFileType","ptr",file.Handle,"uint") != 1 || file.Length < 1 || file.Length > 16384
                throw Error("Luna receipt must be a bounded regular file")
            info := LunaReceipt.SnapshotInfo(file)
            if NumGet(info,0,"uint") & 0x410
                throw Error("Luna receipt is not a regular non-reparse file")
            resolved := Buffer(65536)
            count := DllCall("GetFinalPathNameByHandleW","ptr",file.Handle,"ptr",resolved,"uint",32768,"uint",0,"uint")
            if !count || count >= 32768 || StrLower(StrGet(resolved,"UTF-16")) != StrLower("\\?\" path)
                throw Error("Luna receipt resolved outside its fixed path")
            LunaReceipt.PrivateSecurity(file.Handle,false,true)
            return file
        } catch as err {
            file.Close()
            throw err
        }
    }
    static SnapshotInfo(file) {
        info := Buffer(52,0)
        if !DllCall("GetFileInformationByHandle","ptr",file.Handle,"ptr",info,"int")
            throw Error("Cannot inspect Luna receipt snapshot")
        return info
    }
    static AssertCurrent(file,p) {
        ; Atomic replacement may leave this open handle on old bytes. Never accept a
        ; snapshot whose volume/file identity is no longer at the fixed path.
        LunaReceipt.AssertCurrentInfo(LunaReceipt.SnapshotInfo(file),p)
    }
    static AssertCurrentInfo(before,p) {
        current := LunaReceipt.OpenSnapshot(p)
        try {
            after := LunaReceipt.SnapshotInfo(current)
            for offset in [28,44,48]
                if NumGet(before,offset,"uint") != NumGet(after,offset,"uint")
                    throw Error("Luna receipt changed while being read")
        } finally current.Close()
    }
    static Read(p) {
        file := LunaReceipt.OpenSnapshot(p)
        try {
            bytes := file.Length, data := Buffer(bytes)
            file.Pos := 0
            if file.RawRead(data,bytes) != bytes
                throw Error("Incomplete Luna receipt")
            loop bytes
                if NumGet(data,A_Index-1,"uchar") = 0
                    throw Error("Literal NUL is not valid receipt JSON")
            chars := DllCall("MultiByteToWideChar","uint",65001,"uint",8,"ptr",data,"int",bytes,"ptr",0,"int",0,"int")
            if !chars
                throw Error("Luna receipt is not valid UTF-8")
            wide := Buffer((chars+1)*2,0)
            if !DllCall("MultiByteToWideChar","uint",65001,"uint",8,"ptr",data,"int",bytes,"ptr",wide,"int",chars,"int")
                throw Error("Luna receipt UTF-8 decode failed")
            text := StrGet(wide,chars,"UTF-16")
            LunaReceipt.AssertCurrent(file,p)
        } finally {
            file.Close()
        }
        return GameJson.Load(text)
    }
    static NoReparse(path) {
        current := path
        loop {
            attributes := DllCall("GetFileAttributesW","str",current,"uint")
            if attributes = 0xFFFFFFFF || attributes & 0x400
                throw Error("Luna handoff path is unavailable or contains a reparse point")
            SplitPath(current,,&parent)
            if parent = "" || parent = current
                break
            current := parent
        }
    }
    static SidText(sid) {
        text := 0
        if !sid || !DllCall("advapi32\ConvertSidToStringSidW","ptr",sid,"ptr*",&text,"int")
            throw Error("Cannot inspect Luna handoff SID")
        try return StrGet(text,"UTF-16")
        finally DllCall("LocalFree","ptr",text)
    }
    static CurrentSid() {
        if LunaReceipt.UserSid != ""
            return LunaReceipt.UserSid
        token := 0, length := 0
        if !DllCall("advapi32\OpenProcessToken","ptr",DllCall("GetCurrentProcess","ptr"),"uint",8,"ptr*",&token,"int")
            throw Error("Cannot inspect reader token")
        try {
            DllCall("advapi32\GetTokenInformation","ptr",token,"int",1,"ptr",0,"uint",0,"uint*",&length)
            tokenBuffer := Buffer(length)
            if !DllCall("advapi32\GetTokenInformation","ptr",token,"int",1,"ptr",tokenBuffer,"uint",length,"uint*",&length,"int")
                throw Error("Cannot inspect reader SID")
            LunaReceipt.UserSid := LunaReceipt.SidText(NumGet(tokenBuffer,0,"ptr"))
            return LunaReceipt.UserSid
        } finally DllCall("CloseHandle","ptr",token)
    }
    static PrivateSecurity(target,protectedRequired := false,isHandle := false) {
        owner := 0, dacl := 0, descriptor := 0
        if isHandle
            result := DllCall("advapi32\GetSecurityInfo","ptr",target,"int",1,"uint",5,"ptr*",&owner,"ptr",0,"ptr*",&dacl,"ptr",0,"ptr*",&descriptor,"uint")
        else
            result := DllCall("advapi32\GetNamedSecurityInfoW","str",target,"int",1,"uint",5,"ptr*",&owner,"ptr",0,"ptr*",&dacl,"ptr",0,"ptr*",&descriptor,"uint")
        if result
            throw Error("Cannot inspect private Luna handoff permissions")
        try {
            me := LunaReceipt.CurrentSid()
            if LunaReceipt.SidText(owner) != me || !dacl
                throw Error("Luna handoff is not owned by the current user with an explicit DACL")
            control := 0, revision := 0
            if !DllCall("advapi32\GetSecurityDescriptorControl","ptr",descriptor,"ushort*",&control,"uint*",&revision,"int")
                || (protectedRequired && !(control & 0x1000))
                throw Error("Luna runtime directory requires a protected DACL")
            userRead := false, allowed := Map(me,1,"S-1-5-18",1,"S-1-5-32-544",1)
            loop NumGet(dacl,4,"ushort") {
                ace := 0
                if !DllCall("advapi32\GetAce","ptr",dacl,"uint",A_Index-1,"ptr*",&ace,"int") || NumGet(ace,0,"uchar") != 0
                    throw Error("Unsupported Luna handoff ACL entry")
                sid := LunaReceipt.SidText(ace+8)
                if !allowed.Has(sid)
                    throw Error("Luna handoff permits an unrelated principal")
                if sid = me && (NumGet(ace,4,"uint") & 1)
                    userRead := true
            }
            if !userRead
                throw Error("Luna handoff does not retain current-user read access")
        } finally DllCall("LocalFree","ptr",descriptor)
    }
    static HashFile(path) {
        ; CryptoAPI SHA256 over the selected file only, no executable launch or code loading.
        provider := 0, hash := 0
        if !DllCall("advapi32\CryptAcquireContextW","ptr*",&provider,"ptr",0,"ptr",0,"uint",24,"uint",0xF0000000,"int")
            throw Error("Cannot initialize executable hash")
        try {
            if !DllCall("advapi32\CryptCreateHash","ptr",provider,"uint",0x800C,"ptr",0,"uint",0,"ptr*",&hash,"int")
                throw Error("Cannot create executable SHA256")
            file := FileOpen(path,"r-wd")
            try {
                if file.Length > 1073741824
                    throw Error("Selected executable exceeds the bounded hash size")
                file.Pos := 0
                data := Buffer(1048576)
                while count := file.RawRead(data,data.Size)
                    if !DllCall("advapi32\CryptHashData","ptr",hash,"ptr",data,"uint",count,"uint",0,"int")
                        throw Error("Executable SHA256 read failed")
            } finally file.Close()
            digest := Buffer(32), length := 32
            if !DllCall("advapi32\CryptGetHashParam","ptr",hash,"uint",2,"ptr",digest,"uint*",&length,"uint",0,"int") || length != 32
                throw Error("Executable SHA256 failed")
            out := ""
            loop 32
                out .= Format("{:02X}",NumGet(digest,A_Index-1,"uchar"))
            return out
        } finally {
            if hash
                DllCall("advapi32\CryptDestroyHash","ptr",hash)
            DllCall("advapi32\CryptReleaseContext","ptr",provider,"uint",0)
        }
    }
}


