# Privacy and Data Retention

Transcribe is local-first software. All voice processing, speech recognition, and file storage occur strictly on your physical machine.

---

## 1. On-Device Execution

- **Zero Cloud Reliance**: Audio data is never uploaded to any remote server or third-party service.
- **Localhost Isolation**: The internal engine server binds exclusively to loopback address `127.0.0.1:8765` and rejects non-local connections.
- **No Telemetry**: There is no analytics, tracking, or network telemetry code.
- **Offline Operation**: Model weights are downloaded once from Hugging Face during initial setup. Afterward, dictation and transcription operate entirely offline.

---

## 2. Storage and Automatic Cleanup

Every dictation and file transcription generates two session artifacts:
1. `~/Library/Application Support/transcribe/sessions/YYYYMMDD/<id>.wav` — raw 16 kHz audio.
2. `~/Library/Application Support/transcribe/sessions/YYYYMMDD/<id>.json` — transcript text and metadata (model, language, duration, timestamp).

### Time-to-Live (TTL) Policy
- Sessions are **automatically deleted after 48 hours** (`cleanup_ttl_hours: 48.0`).
- Cleanup runs automatically:
  - On every CLI command execution.
  - On engine server startup.
  - After every dictation completes.
  - When selecting **Clean Up Old Recordings** in the menu-bar app.

### Immediate Deletion Mode
- The Swift menu-bar app deletes its own temporary WAV file immediately after transcribing.
- To disable session retention completely and delete records immediately upon completion:
  ```bash
  transcribe config set cleanup_ttl_hours 0
  ```

---

## 3. macOS Permissions

- **Microphone**: Used exclusively while actively dictating (between start and stop hotkey taps).
- **Accessibility**: Used only to emit synthetic `⌘V` key events for pasting into your focused application. If disabled, Transcribe copies text to the pasteboard without pasting.
