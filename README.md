# OCR Boxes

Windows desktop OCR and text-to-speech by Casey Shingledecker.

Place up to four adjustable OCR boxes over visible text in any window or display. Windows OCR is built in; CPU RapidOCR is optional. The application starts stopped.

## Current edition — 2026-10-20

- General window/display capture, independent of game profiles.
- Kokoro-matched charcoal interface; control layout checked at 96 and 120 DPI.
- A separate voice for each OCR box while retaining the selected player. Kokoro and allowed installed SAPI voices expose per-box choices. A change applies to future utterances, preserving the active sentence.
- Kokoro playback opens the current Windows default output for each utterance. No voice models or cloned voices are included.
- Optional native Edge Read Aloud, adapted from Game Voice Reader's approach, without MB5. It requires explicit focus consent and uses one shared browser-managed voice. Native spoken playback remains unverified; discovery, document readiness and cleanup passed a silent test.

## Run

Requires Windows 10/11 and AutoHotkey v2, installed from its official site. Keep the three folders together, then run `OcrBoxes/OCR Boxes.ahk`. Use + or **Fit box to window / display**, position the box, lock it, and press Play.

To configure optional RapidOCR, run `Setup-RapidOCR.ps1` in PowerShell. It uses an existing Python installation to create a local virtual environment and installs the declared PyPI requirements. It does not download Python or AutoHotkey. Kokoro requires your own running compatible service on 127.0.0.1:8787.

The source package excludes personal settings, game inventory, captured text, logs, model weights and character artwork. Guarded game configuration must be supplied and verified separately. Captures are fixed visible screen areas, not background/window-tracking capture.

## Validation

16 silent per-box/queue/layout checks and 105 existing self-tests passed on the author's Windows PC. Actual headset sound and native Edge speech have not been independently verified. Tests do not establish compatibility with every display, game or voice service.

## Credits and rights

The Windows OCR library is by Descolada (MIT), based on malcev's UWP work. The native Edge workflow was informed by KnightDevRedEmber/GameVoiceReader (MIT). Full notices are in `notices/`. Runtime packages retain their own licenses. Casey's original project source is published for inspection; no additional license for that source or third-party artwork/models is granted by this repository.
