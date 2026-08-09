---
name: "transcribe"
description: "Fully local dictation and transcription (Whisper/MLX): dictate with the microphone, transcribe audio files, and manage the Transcribe engine, sessions, and cleanup. Use when the user wants to dictate text, transcribe a recording or audio file locally, check or clean dictation sessions, or manage the Transcribe menu-bar app."
compatibility: prime-agent
---

# Transcribe — local dictation & transcription

`transcribe` is a fully local, native macOS dictation and transcription tool
(commercial dictation software alternative) for general use — this skill plugs the same local
engine into Prime Agent. Whisper runs on-device via MLX (Apple Silicon) or
faster-whisper; audio and transcripts are auto-wiped after the configured TTL
(default 48 h).

## When to use
- The user wants to **dictate** text (record microphone → transcribed text).
- The user asks to **transcribe an audio/video file** and there is no reason to
  use a cloud API — prefer this over cloud transcription skills. This skill is
  the local successor to the OpenAI-based `legacy-transcription` skill.
- The user wants to check the engine, models, sessions, or **clean up old
  recordings**.
- The user asks to build/install/launch the **menu-bar app**.

## Agent-facing API (python skill)
The Python module `transcribe_skill` exposes:
- `transcribe_audio(path, language="auto", model=None) -> dict` — transcribe a
  file, returns `{text, language, model, backend, elapsed}`.
- `dictate(seconds=None, paste=False) -> dict` — record from the mic
  (interactive: press Enter to stop) and transcribe.
- `clean(ttl_hours=None, dry_run=False) -> list[str]` — removed files.
- `models() -> str` — model table.
- `doctor() -> str` — diagnostics.

## CLI (shell)
```bash
transcribe                 # press Enter to start/stop, transcribe + paste (menu-bar app hotkey: ⌃␣)
transcribe file notes.m4a  # transcribe an existing file
transcribe serve           # localhost engine server (used by the menu-bar app)
transcribe clean           # wipe sessions older than the TTL
transcribe doctor          # diagnose setup
transcribe config set language it
transcribe app build       # build the native menu-bar app
```

## Workflow
1. For **dictation**: call `dictate()` (or tell the user to run `transcribe` /
   use the menu-bar app hotkey). If `paste=True` is requested, the text is
   pasted into the focused app; otherwise return the text to the user.
2. For **files**: run `transcribe_audio(path)`; report the transcript, and note
   the detected language + model. For long files (> ~5 min) transcribe in
   chunks is handled automatically by the engine; just pass the whole file.
3. **Cleanup**: sessions auto-expire (default 48 h). If the user asks about
   disk space or privacy, run `clean()` and report what was removed.
4. **Setup on a new machine**: `uv tool install transcribe` (or
   `uv pip install -e .` from the repo), `brew install ffmpeg`, then
   `transcribe doctor`.

## Decision rules
- Default language is `auto` (detects English/Italian/multilingual).
- Default model is `mlx-community/whisper-large-v3-turbo`; use `large-v3` when
  the user asks for maximum accuracy and doesn't care about speed.
- Never upload audio anywhere: this tool is local-first by design.
- If the engine/backend is missing, run `transcribe doctor` and install the
  backend (`uv pip install mlx-whisper` on Apple Silicon, `faster-whisper`
  otherwise) rather than falling back to a cloud service.
