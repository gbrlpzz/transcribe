# Architecture

Transcribe is deliberately small: one Python engine, two thin front-ends (a
native menu-bar app and a Prime Agent skill), and a localhost HTTP server
between them.

```
┌───────────────┐   WAV (16 kHz mono)    ┌───────────────────────────┐
│  menu-bar app │ ─────────────────────▶ │  engine server            │
│  (Swift)      │   POST /transcribe     │  (Python, 127.0.0.1:8765) │
│  hotkey · mic │ ◀───────────────────── │  Whisper large-v3-turbo   │
│  paste        │   {"text": "..."}      │  · MLX or faster-whisper  │
└───────────────┘                        └─────────────┬─────────────┘
                                                       │ sessions/
┌───────────────┐   subprocess / import                │ (wav + json,
│  CLI          │ ─────────────────────────────────────▶  TTL cleanup)
│  transcribe   │
└───────────────┘
┌──────────────────────────┐
│  Prime Agent skill       │  import transcribe → same engine
│  transcribe_skill.py     │
└──────────────────────────┘
```

## Components

| Module | Responsibility |
|---|---|
| `transcribe/audio.py` | Microphone capture via ffmpeg's AVFoundation input → raw s16le → wrapped as 16 kHz mono WAV. Zero extra deps beyond ffmpeg. |
| `transcribe/engine.py` | Whisper backends. `mlx-whisper` on Apple Silicon, `faster-whisper` fallback. Model registry with short aliases. |
| `transcribe/smarttext.py` | Spoken-punctuation post-processing: "comma" → `,`, "new line" → newline, "delete that" → removes previous word. Whole-word matching so ordinary speech is untouched. |
| `transcribe/storage.py` | Session store: `sessions/YYYYMMDD/<id>.wav` + `<id>.json`, with time-to-live cleanup. |
| `transcribe/server.py` | `ThreadingHTTPServer` on 127.0.0.1. `/health`, `/transcribe`, `/reload`. Warmed model, serialized by a lock. |
| `transcribe/cli.py` | Subcommands: `listen`, `file`, `serve`, `clean`, `config`, `models`, `doctor`, `app`. |
| `app/` | Swift menu-bar app (AppKit + Carbon). Global hotkey, AVAudioRecorder, pasteboard + Cmd+V paste, engine lifecycle. |
| `skill/` | Prime Agent skill: `SKILL.md` (markdown contract) + `transcribe_skill.py` (Python API). |

## Data flow (one dictation)

1. Hotkey pressed → `Recorder.start()` writes a WAV to a temp file.
2. Hotkey released → the app POSTs `{"path": …, "language": …}` to the server.
3. The server transcribes with the warmed model, saves a session copy, responds with `{"text": …}`.
4. The app puts the text on the pasteboard and sends Cmd+V (Accessibility).
5. The app deletes its temp WAV; the session copy expires via TTL cleanup.

## Why this shape

- **Server, not per-request subprocess** — the model stays loaded, so a
  dictation round-trip is ~1–3 s instead of 5–10 s.
- **Path-based upload** — the app and server run on the same machine and user,
  so the app passes the file path instead of streaming bytes.
- **One config file** — Swift `AppConfig` and Python `Config` serialize the same
  JSON, so menu choices and CLI settings stay in sync.
