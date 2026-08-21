---
name: "transcribe"
description: "Fully local dictation and transcription (Whisper/MLX): dictate with the microphone, transcribe audio files, and manage the Transcribe engine, sessions, and cleanup."
compatibility: prime-agent
---

# Transcribe — local dictation and transcription

Transcribe is a local macOS dictation and transcription tool. It uses one warm
Whisper turbo model through the local engine. Audio stays on the Mac.

## When to use

- The user wants to dictate text.
- The user wants to transcribe an audio or video file locally.
- The user wants to inspect or clean old sessions.
- The user wants to check or install the local daemon and engine.

## Agent-facing API

The `transcribe_skill` module exposes:

- `transcribe_audio(path, language="auto", model=None) -> dict`
- `dictate(seconds=None, paste=False) -> dict`
- `clean(ttl_hours=None, dry_run=False) -> list[str]`
- `models() -> str`
- `doctor() -> str`

## CLI

```bash
transcribe                 # run the resident dictation daemon
transcribe file notes.m4a  # transcribe an existing file
transcribe serve           # run the local engine
transcribe clean           # remove expired sessions
transcribe doctor          # check setup
transcribe models          # show the tested model profile
transcribe config set language it
transcribe ping            # check the resident engine socket
```

## Workflow

1. For dictation, call `dictate()` or tell the user to use the resident `⌃␣` hotkey.
2. For files, call `transcribe_audio(path)` and report the text, language, model,
   and elapsed time.
3. For cleanup, call `clean()` when the user asks to remove expired sessions.
4. On a new machine, install `ffmpeg`, install the engine with the MLX extra on
   Apple Silicon or the fallback extra on other systems, and run `transcribe doctor`.

## Decision rules

- The default language is `auto`.
- The supported model profile is `turbo-q4` (`mlx-community/whisper-large-v3-turbo-4bit` on Apple Silicon, with the pinned fallback backend on other Macs).
- Do not upload audio or use a cloud fallback.
- If the engine is missing, run `transcribe doctor` and install the local backend.
- Sessions expire after the configured TTL, which defaults to one hour for live data and seven days for generated file transcripts.
