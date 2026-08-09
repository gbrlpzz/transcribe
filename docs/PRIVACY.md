# Privacy

Transcribe is local-first by design. This document states exactly what happens
with your audio and text.

## On-device only

- Speech recognition runs **on your Mac** via MLX Whisper or faster-whisper.
- The engine server binds to `127.0.0.1` and accepts connections only from the
  local machine.
- No API keys are needed. Nothing is uploaded, streamed, or shared.
- Model weights are downloaded once from Hugging Face into the local cache;
  after that, transcription works offline.

## What is stored, and for how long

Every dictation/file transcription produces:

- `sessions/YYYYMMDD/<id>.wav` — the audio
- `sessions/YYYYMMDD/<id>.json` — the transcript + metadata (model, language,
  duration, timestamp)

under `~/Library/Application Support/transcribe/`. Both are deleted
automatically after `cleanup_ttl_hours` (default **48 hours**). Cleanup runs:

- on every CLI command,
- when the engine server starts,
- after every dictation,
- when you pick **Clean Up Old Recordings** in the app menu.

Set `cleanup_ttl_hours` to `0` to delete sessions immediately after
transcription (`transcribe config set cleanup_ttl_hours 0`). The menu-bar app
additionally deletes its own temp WAV right after each dictation, regardless of
the TTL.

## Permissions

- **Microphone** — required to record; used only while you are holding the
  hotkey (or while the CLI is recording).
- **Accessibility** — required only to *paste* text into the focused app
  (synthetic Cmd+V). The app works without it if you disable `paste` in the
  config; text is then copied to the clipboard instead.
