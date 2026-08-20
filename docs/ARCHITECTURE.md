# Architecture

Transcribe has four local parts:

1. A native macOS menu-bar app.
2. A Python engine server.
3. A command-line interface.
4. An optional Prime Agent skill.

All communication stays on `127.0.0.1:8765`.

```text
Menu-bar app ── POST /transcribe ──▶ Python engine
     │                                   │
     │                                   ├── one warm turbo model
     │                                   ├── MLX on Apple Silicon
     │                                   └── session storage with TTL cleanup
     │
     ├── microphone recorder
     ├── Notch HUD
     ├── paste support
     └── Finder file events

CLI and Prime Agent skill ──────────────▶ same engine server
```

## Core components

| Component | Location | Responsibility |
|---|---|---|
| `DictationPill` | `app/Sources/Transcribe/DictationPill.swift` | Displays recording, transcription, result, error, and cancellation states. Uses a native macOS spinner for indeterminate work. |
| `Recorder` | `app/Sources/Transcribe/Recorder.swift` | Captures 16 kHz mono PCM WAV audio and exposes input levels. |
| `EngineClient` | `app/Sources/Transcribe/EngineClient.swift` | Starts the local engine and sends transcription requests. |
| `AppDelegate` | `app/Sources/Transcribe/AppDelegate.swift` | Coordinates live dictation, Finder files, queueing, HUD layout, cancellation, and output. |
| `HotKey` | `app/Sources/Transcribe/HotKey.swift` | Registers the global tap-to-toggle shortcut through Carbon. |
| `Paste` | `app/Sources/Transcribe/Paste.swift` | Copies text and sends `⌘V` through macOS Accessibility. |
| `Engine` | `transcribe/engine.py` | Loads the tested `turbo` model and selects MLX or the fallback backend. |
| `Server` | `transcribe/server.py` | Exposes `/health`, `/transcribe`, and `/reload`. Runs warm-up and inference on one dedicated engine thread. |
| `Storage` | `transcribe/storage.py` | Stores sessions and removes expired data. |
| `CLI` | `transcribe/cli.py` | Provides dictation, file, server, cleanup, configuration, and diagnostics commands. |

## Inference and concurrency

The engine keeps one model warm. MLX GPU streams are thread-local, so warm-up and inference run on the same dedicated thread.

The app keeps live and file state separate:

- Live recording can continue while a file is being transcribed.
- File jobs are queued and cancellable.
- The HUD shows a large file pill alone.
- During overlap, the live pill is medium and left-aligned. The file becomes a spinner circle on the right.
- Model requests remain serialized. This avoids a second model copy and limits memory pressure.

## Data flow

1. The user starts dictation with the global hotkey.
2. The app records a temporary 16 kHz WAV file.
3. The app sends its local path to `/transcribe`.
4. The engine transcribes the file with the warm model.
5. The engine stores a session record and returns text.
6. Live text is pasted into the focused app.
7. The app removes temporary microphone recordings.
8. Finder file requests set `preserve_source: true`, write `<file>.md` beside the original, and track that generated output for file-TTL cleanup.

## Configuration

Swift and Python share this file:

```text
~/Library/Application Support/transcribe/config.json
```

The release profile uses the `turbo` model, the selected language, the local port, paste settings, a one-hour live cleanup TTL, and a seven-day file transcript TTL.
