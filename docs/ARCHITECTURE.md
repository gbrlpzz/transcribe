# Architecture

One Swift package, one binary, no server.

```
menu-bar app (SwiftUI-free AppKit)          transcribe CLI
  hotkey · HUD pill · paste · queue           file · doctor · languages
        │                                            │
        └────────────► single Mach-O binary ◄────────┘
             argv[0] basename picks app vs CLI mode
                            │
                 TranscribeCore (library)
             ├─ SpeechDictationEngine   mic tap → 16 kHz mono i16 → SpeechAnalyzer (streaming)
             ├─ FileTranscriber         AVAudioFile → SpeechAnalyzer (finishAfterFile)
             ├─ LocaleManager           functional readiness truth, watchdog-wrapped installs
             ├─ SessionStore            ~/Library/Application Support/transcribe/sessions/<YYYYMMDD>/
             ├─ AppConfig               config.json (hotkey, locale, retention TTLs)
             └─ SpeechPermissions       mic → speech ordering before any analyzer runs
```

Everything runs on Apple's on-device speech stack (macOS 26 `SpeechAnalyzer` /
`SpeechTranscriber`). There is no server, port, or health endpoint. The CLI is the
same binary invoked under the name `transcribe` — see skill/transcribe/SKILL.md.

Measured reference points live in CHANGELOG.md; API behavior notes in
docs/APPLE-SPEECH-API-NOTES.md.
