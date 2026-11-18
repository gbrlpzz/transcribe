# Architecture

One Swift package, one binary, no server.

```
menu-bar app (SwiftUI-free AppKit)          transcribe CLI
  hotkey · HUD pill · paste · queue           transcribe <audio>... [--json] [--locale]
  updater                                            │
        │                                            │
        └────────────► single Mach-O binary ◄────────┘
             argv[0] basename picks app vs CLI mode
                            │
             TranscribeCLI (library)
             ├─ TranscribeCLI           argument parsing, locale gate, exit codes
             └─ FileTranscriber         AVAudioFile → SpeechAnalyzer (finishAfterFile) → <file>.md
                            │
             TranscribeCore (library)
             ├─ SpeechDictationEngine   mic tap → 16 kHz mono i16 → SpeechAnalyzer (streaming)
             ├─ Transcript              several languages → one text; vocabulary pass (pure)
             ├─ LocaleManager           functional readiness truth, watchdog-wrapped installs
             ├─ AppConfig               config.json (hotkey, locale, vocabulary)
             └─ SpeechPermissions       mic → speech ordering before any analyzer runs
```

Everything runs on Apple's on-device speech stack (macOS 26 `SpeechAnalyzer` /
`SpeechTranscriber`). There is no server, port, or health endpoint, and nothing is
archived: a dictation lives in the clipboard, a file transcript in the `.md` beside the
audio. The CLI is the same binary invoked under the name `transcribe` — see
skill/transcribe/SKILL.md.

Auto runs one transcriber per preferred language on the same audio. Each reports words
with a time range and a confidence; `Transcript` scores the lanes second by second, takes
the best path through them (a switch has to earn its keep), and cuts between lanes at
sentence ends. A pinned language with no vocabulary bypasses all of it.

Measured reference points live in CHANGELOG.md; API behavior notes in
docs/APPLE-SPEECH-API-NOTES.md. docs/LEGGERISSIMO-DESIGN.md is the original design record.
