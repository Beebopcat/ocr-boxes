#Requires AutoHotkey v2.0
; ============================================================================
;  BoxLogic.ahk - the pure logic of OCR Boxes.  Nothing in this file touches the screen, the network, a window or audio,
;  so  AutoHotkey64.exe "OCR Boxes.ahk" --selftest out.txt  can check all of it on any Windows PC.
;
;    NormText / WordSim / SkipWords   compare what the OCR returned for the same box a moment ago
;    Lane                             one source of text (OCR Box 1..4, Luna Translator): a strict first-in first-out queue
;    Reader                           picks what is spoken next: Box 1 -> 2 -> 3 -> 4 -> Luna -> repeat, boxes with nothing new are skipped
;    SigDiff / ChangeTracker          "has the picture in this box really changed, and has it stopped changing?"
;    CleanText / LinesToText / Score  the text helpers of Game Voice Reader (unchanged, they are what F21/F22 use)
; ============================================================================

; Lower-case letters and digits only: punctuation and OCR noise between two looks at the same text must not make it look new.
NormText(s) {
    s := StrLower(s)
    s := RegExReplace(s, "[^\p{L}\p{N}]+", " ")
    return Trim(s)
}

; Share of distinct words two normalised strings have in common (1 = same words).  Cheap, and forgiving of one misread letter.
WordSim(a, b) {
    if a = b
        return 1.0
    wa := Map(), wb := Map()
    for w in StrSplit(a, " ")
        wa[w] := 1
    for w in StrSplit(b, " ")
        wb[w] := 1
    if !wa.Count || !wb.Count
        return 0.0
    common := 0
    for w in wa
        if wb.Has(w)
            common += 1
    return common / (wa.Count + wb.Count - common)
}

; The part of `raw` that follows its first n words (a word = a run of letters or digits, the same split NormText uses).
SkipWords(raw, n) {
    pos := 1
    Loop n {
        if !RegExMatch(raw, "[\p{L}\p{N}]+", &m, pos)
            return ""
        pos := m.Pos + m.Len
    }
    return Trim(SubStr(raw, pos), " `t`r`n.,;:-")
}

; a unless it is empty, then b
Nz(a, b) {
    return a != "" ? a : b
}

WordCount(norm) {
    return norm = "" ? 0 : StrSplit(norm, " ").Length
}

; ---------------------------------------------------------------------------------------------------------------------
;  Lane: strict FIFO.  Offer() is where a new OCR result is judged against the previous one from the same source.
; ---------------------------------------------------------------------------------------------------------------------
class Lane {
    static Seq := 0                                   ; arrival order across all lanes (for order=time)
    __New(name, cap := 200, rememberMs := 0) {
        this.exact := false
        this.name := name
        this.cap := cap
        this.rememberMs := rememberMs                 ; 0 = a repeat is a repeat for as long as the text stays; >0 = forget after this long
        this.items := []                              ; {text, norm, seq}
        this.lastNorm := ""
        this.lastAt := 0
        this.dropped := 0
    }
    Count => this.items.Length

    ; Returns "blank" (nothing readable: forgets the last text, so the same words coming back later are new again),
    ;         "same" (still the text we already took), "extended" (a typed-out line grew and the short version had not been read yet:
    ;         the queued item was replaced), "tail" (it grew after the short version was read: only the new words are queued) or "queued".
    Offer(text, now := 0, session := 0) {
        norm := this.exact ? RegExReplace(Trim(text), "\s+", " ") : NormText(text)
        if norm = "" {
            this.lastNorm := ""
            return "blank"
        }
        if this.lastNorm != "" && this.rememberMs > 0 && now - this.lastAt > this.rememberMs
            this.lastNorm := ""
        this.lastAt := now
        if this.exact && norm = this.lastNorm
            return "same"
        if !this.exact && this.lastNorm != "" {
            n := StrLen(this.lastNorm)
            ; A line that is being typed out grows word by word.  This test comes first: one extra word on a six-word line is
            ; 86 % similar, which would otherwise be called "same" and the last word of the line would never be read.
            if StrLen(norm) > n && SubStr(norm, 1, n) = this.lastNorm && SubStr(norm, n + 1, 1) = " " {
                last := this.items.Length ? this.items[this.items.Length] : 0
                if last && last.norm = this.lastNorm {
                    last.text := text
                    last.norm := norm
                    last.session := session
                    this.lastNorm := norm
                    return "extended"
                }
                tail := SkipWords(text, WordCount(this.lastNorm))
                this.lastNorm := norm
                if tail != "" {
                    this.Push(tail, NormText(tail), session)
                    return "tail"
                }
                return "same"
            }
            if WordSim(norm, this.lastNorm) >= 0.85
                return "same"
        }
        this.Push(text, norm, session)
        this.lastNorm := norm
        return "queued"
    }
    Push(text, norm, session := 0) {
        Lane.Seq += 1
        this.items.Push({text: text, norm: norm, seq: Lane.Seq, session: session})
        while this.items.Length > this.cap {
            this.items.RemoveAt(1)
            this.dropped += 1
        }
    }
    Pop() => this.items.RemoveAt(1)
    PutBack(item) => this.items.InsertAt(1, item)
    Clear() {
        this.items := []
    }
}

; ---------------------------------------------------------------------------------------------------------------------
;  Reader: order "box" = one line per lane in turn (Box 1, 2, 3, 4, Luna, 1, ...), always the oldest line of that lane;
;          order "time" = whatever arrived first, from any lane.
; ---------------------------------------------------------------------------------------------------------------------
class Reader {
    __New(lanes, order := "box") {
        this.lanes := lanes
        this.order := order
        this.last := 0
    }
    Total() {
        n := 0
        for lane in this.lanes
            n += lane.Count
        return n
    }
    Next() {
        n := this.lanes.Length
        if this.order = "time" {
            best := 0
            for i, lane in this.lanes
                if lane.Count && (!best || lane.items[1].seq < this.lanes[best].items[1].seq)
                    best := i
            if !best
                return 0
            this.last := best
            return {lane: this.lanes[best], item: this.lanes[best].Pop()}
        }
        Loop n {
            i := Mod(this.last + A_Index - 1, n) + 1
            if this.lanes[i].Count {
                this.last := i
                return {lane: this.lanes[i], item: this.lanes[i].Pop()}
            }
        }
        return 0
    }
}

; ---------------------------------------------------------------------------------------------------------------------
;  Frame comparison.  A signature is a small BGRA picture of the box (see SampleSig in BoxIO.ahk).
;  SigDiff = share of its cells whose brightness moved by more than `tol` (0..255); compression noise stays below that.
; ---------------------------------------------------------------------------------------------------------------------
SigDiff(a, b, cells, tol := 40) {
    bytes := cells * 4
    if DllCall("ntdll\RtlCompareMemory", "ptr", a, "ptr", b, "uptr", bytes, "uptr") = bytes
        return 0.0
    changed := 0
    Loop cells {
        o := (A_Index - 1) * 4
        x := NumGet(a, o, "uint")
        y := NumGet(b, o, "uint")
        if x = y
            continue
        la := (((x >> 16) & 0xFF) + 2 * ((x >> 8) & 0xFF) + (x & 0xFF)) >> 2
        lb := (((y >> 16) & 0xFF) + 2 * ((y >> 8) & 0xFF) + (y & 0xFF)) >> 2
        if Abs(la - lb) > tol
            changed += 1
    }
    return changed / cells
}

; ---------------------------------------------------------------------------------------------------------------------
;  ChangeTracker, one per locked box, stepped on every look (100 ms):
;    idle      the picture matches the last one we took a snapshot of
;    changing  it differs from that snapshot by at least diffFrac; wait until it stops moving (typed-out text, fades), then snapshot.
;  A box that never settles (scrolling credits, a video behind the text) is snapshotted every maxSettleMs anyway.
; ---------------------------------------------------------------------------------------------------------------------
class ChangeTracker {
    __New(diffFrac := 0.015, settleFrac := 0.0006, stableLooks := 2, maxSettleMs := 2500) {
        this.diffFrac := diffFrac
        this.settleFrac := settleFrac
        this.stableLooks := stableLooks
        this.maxSettleMs := maxSettleMs
        this.Reset()
    }
    Reset() {
        this.state := "idle"
        this.since := 0
        this.calm := 0
        this.peak := 0
    }
    ; dRef: difference to the last snapshot.  dPrev: difference to the look before this one.
    ; Returns "snapshot", "reverted" (it moved, then went back to what the last snapshot showed - a flash, a tooltip, a cursor passing over: nothing to read) or "".
    Step(dRef, dPrev, now) {
        if this.state = "idle" {
            if dRef >= this.diffFrac {
                this.state := "changing"
                this.since := now
                this.calm := 0
                this.peak := dRef
            }
            return ""
        }
        this.peak := Max(this.peak, dRef)
        this.calm := (dPrev <= this.settleFrac) ? this.calm + 1 : 0
        if this.calm >= this.stableLooks || now - this.since >= this.maxSettleMs {
            this.state := "idle"
            return (dRef < this.diffFrac / 2) ? "reverted" : "snapshot"
        }
        return ""
    }
}

; Rough time to read a text aloud, for engines that cannot tell us when they are done.
SpeechEstimateMs(text) {
    return Max(1500, StrLen(text) * 75)
}

; ---------------------------------------------------------------------------------------------------------------------
;  Text helpers, copied unchanged from Game Voice Reader.ahk (F21 / F22 use exactly these).
; ---------------------------------------------------------------------------------------------------------------------
; Rebuild paragraphs from OCR lines: wrapped lines are joined, real paragraph gaps are kept.
LinesToText(lines) {
    hs := 0
    n := 0
    mw := 0
    for ln in lines {
        hs += ln.h
        n += 1
        mw := Max(mw, ln.w)
    }
    if !n
        return ""
    ah := hs / n
    out := ""
    prev := 0
    for ln in lines {
        t := Trim(ln.Text)
        if !RegExMatch(t, "[A-Za-z0-9]")
            continue
        if !prev {
            out := t
        } else {
            gap := ln.y - (prev.y + prev.h)
            if gap > ah * 0.8
                out .= "`n`n" t
            else if RegExMatch(prev.t, "[A-Za-z]-$") && RegExMatch(t, "^[a-z]")
                out := SubStr(out, 1, -1) t
            else if RegExMatch(prev.t, "[.!?:][\x22'\x{2019}\x{201D})\]]*$") && RegExMatch(t, "^[A-Z\x22\x{201C}\x{2018}']") && prev.w < mw * 0.75
                out .= "`n" t
            else
                out .= " " t
        }
        prev := {y: ln.y, h: ln.h, w: ln.w, t: t}
    }
    return out
}
CleanText(s) {
    s := StrReplace(s, "`r", "")
    s := RegExReplace(s, "[\x{00A0}\x{200B}\x{FEFF}]", " ")
    s := RegExReplace(s, "[|\x{00A6}~^``]", "")               ; stray OCR symbols
    s := RegExReplace(s, "[ \t]{2,}", " ")
    s := RegExReplace(s, "[ \t]+([,.;:!?])", "$1")
    s := RegExReplace(s, "\.{4,}", "...")
    s := RegExReplace(s, "(?m)^[ \t]+|[ \t]+$", "")
    s := RegExReplace(s, "\n{3,}", "`n`n")
    return Trim(s, " `t`r`n")
}
; Rough "does this look like real words" score: letter ratio x number of vowel-bearing words.
Score(text) {
    compact := RegExReplace(text, "\s+", "")
    if StrLen(compact) < 3
        return 0
    letters := StrLen(RegExReplace(compact, "[^A-Za-z]"))
    words := 0
    pos := 1
    while pos := RegExMatch(text, "i)\b[a-z']{2,}\b", &m, pos) {
        if RegExMatch(m[0], "i)[aeiouy]")
            words += 1
        pos += m.Len
    }
    return (letters / StrLen(compact)) * words
}

; Work areas are rediscovered by the caller. Negative coordinates are valid.
; This constrains the control bar only; OCR boxes can cross any monitor boundary.
FitWorkRect(x, y, w, h, areas, primary := 1) {
    best := areas[primary]
    if !RegExMatch(x "", "^-?\d+$") || !RegExMatch(y "", "^-?\d+$") {
        x := best.r - w - 40
        y := best.t + 40
    } else {
        x := Integer(x)
        y := Integer(y)
    }
    overlap := 0
    for area in areas {
        size := Max(0, Min(x + w, area.r) - Max(x, area.l)) * Max(0, Min(y + h, area.b) - Max(y, area.t))
        if size > overlap {
            overlap := size
            best := area
        }
    }
    return {x: Min(Max(x, best.l), Max(best.l, best.r - w)),
            y: Min(Max(y, best.t), Max(best.t, best.b - h))}
}

