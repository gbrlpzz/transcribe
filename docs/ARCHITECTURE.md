# Architecture

Transcribe consists of a Python engine server, a native macOS Swift menu-bar app, an optional Prime Agent skill, and a command-line interface. All components communicate locally over localhost (`127.0.0.1:8765`).

```
┌───────────────────────────┐     WAV (16 kHz mono)     ┌───────────────────────────┐
│  Menu-bar App (Swift)     │ ────────────────────────▶ │  Engine Server (Python)   │
│  • Global hotkey          │     POST /transcribe      │  • 127.0.0.1:8765         │
│  • Notch HUD pill         │ ◀──────────────────────── │  • Whisper large-v3-turbo │
│  • Paste / Clipboard      │     {"text": "..."}       │  • MLX / faster-whisper   │
└───────────────────────────┘                           └─────────────┬─────────────┘
                                                                      │
┌───────────────────────────┐     CLI commands                        │ Sessions (WAV + JSON)
│  CLI (Python)             │ ────────────────────────────────────────┤ (TTL auto-cleanup)
│  transcribe file/listen   │                                         │
└───────────────────────────┘                                         ▼
┌───────────────────────────┐                          ~/Library/Application Support/
│  Prime Agent Skill        │                           transcribe/sessions/
│  transcribe_skill.py      │
└───────────────────────────┘
```

---

## Core Components

| Module | Location | Responsibility |
|---|---|---|
| `DictationPill` | `app/Sources/Transcribe/DictationPill.swift` | Floating obsidian frosted-glass HUD anchored under the screen notch. Renders 60 FPS live waveform, transcribing dots, and status checkmarks. |
| `Recorder` | `app/Sources/Transcribe/Recorder.swift` | Captures microphone input at 16 kHz mono 16-bit PCM WAV. Exposes live metering levels to the HUD. |
| `EngineClient` | `app/Sources/Transcribe/EngineClient.swift` | Manages the background engine process lifecycle and sends HTTP requests to `127.0.0.1:8765`. |
| `Paste` | `app/Sources/Transcribe/Paste.swift` | Copies text to pasteboard and synthesizes `⌘V` key events via macOS Accessibility. |
| `HotKey` | `app/Sources/Transcribe/HotKey.swift` | Global tap-to-toggle keyboard shortcut listener using the Carbon Event Manager API. |
| `Audio` | `transcribe/audio.py` | CLI recording via ffmpeg AVFoundation input. Captures 16 kHz mono WAV with silence trimming. |
| `Engine` | `transcribe/engine.py` | Whisper model registry and inference execution. Routes to `mlx-whisper` on Apple Silicon or `faster-whisper` on Intel. |
| `SmartText` | `transcribe/smarttext.py` | Spoken punctuation and editing post-processor ("comma" → `,`, "new line" → `
`, "delete that" → removes prior word). |
| `Storage` | `transcribe/storage.py` | Manages session persistence and time-to-live (TTL) automatic file deletion. |
| `Server` | `transcribe/server.py` | `ThreadingHTTPServer` exposing `/health`, `/transcribe`, and `/reload`. Keeps model loaded in RAM for fast dictation responses. |
| `CLI` | `transcribe/cli.py` | Tyro CLI interface exposing commands (`listen`, `file`, `serve`, `clean`, `config`, `models`, `doctor`). |

---

## Dictation Data Flow

1. **Start**: The user taps `⌃␣`. `HotKey` detects the keypress, `Recorder` starts writing 16 kHz PCM WAV, and `DictationPill` drops down from the notch displaying a 60 FPS live audio waveform.
2. **Stop**: The user taps `⌃␣` again. `Recorder` stops writing audio and `DictationPill` morphs into an undulating loading indicator.
3. **Inference**: `EngineClient` posts the temporary WAV file path to `http://127.0.0.1:8765/transcribe`.
4. **Smart Text**: The engine transcribes audio using the warm Whisper model in memory, applies smart punctuation rules, saves a session record, and returns the final text payload.
5. **Output**: `Paste` places the text on the macOS pasteboard and emits a synthetic `⌘V` key event. `DictationPill` shows a green checkmark confirmation and fades out after 1.6 seconds.
6. **Cleanup**: The Swift app deletes the temporary recording WAV immediately. The engine session record expires after the configured TTL (default: 48 hours).

---

## Design Principles

- **Persistent In-Memory Model**: The model stays loaded in unified memory on Apple Silicon. Dictation round-trips take ~1–2 seconds instead of restarting the Python runtime each time.
- **Local Path Sharing**: The front-end app and engine server share the local filesystem under the same user account. The app passes local file paths rather than streaming large audio payloads over HTTP sockets.
- **Unified Configuration**: Swift (`AppConfig`) and Python (`Config`) read and write the exact same JSON schema at `~/Library/Application Support/transcribe/config.json`.
