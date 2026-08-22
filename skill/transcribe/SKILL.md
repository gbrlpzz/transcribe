---
name: "transcribe"
description: "Fully local dictation and transcription (Whisper/MLX): dictate with the microphone, transcribe audio files, and manage the Transcribe engine, sessions, and cleanup."
compatibility: prime-agent
---

# Transcribe — local dictation and transcription

Transcribe is a local macOS dictation and transcription tool. It uses one warm
4-bit Whisper turbo model through the local engine, with automatic per-utterance
language detection. Audio stays on the Mac.

## When to use

- The user wants to dictate text.
- The user wants to transcribe an audio or video file locally.
- The user wants to inspect or clean old sessions.
- The user wants to check or install the menu-bar app.

## Agent-facing API

The `transcribe_skill` module exposes:

- `transcribe_audio(path, smart_text=None) -> dict`
- `dictate(seconds=None, paste=False) -> dict`
- `clean(ttl_hours=None, dry_run=False) -> list[str]`
- `doctor() -> str`

## CLI

```bash
transcribe                 # dictate and paste
transcribe file notes.m4a  # transcribe an existing file
transcribe start           # start the background engine
transcribe restart         # restart it (first fix for any hiccup)
transcribe serve           # run the engine in the foreground
transcribe clean           # remove expired sessions
transcribe doctor          # check setup
transcribe app build       # build the menu-bar app
```

## Workflow

1. For dictation, call `dictate()` or tell the user to use the menu-bar hotkey.
2. For files, call `transcribe_audio(path)` and report the text, language,
   model, and elapsed time.
3. For cleanup, call `clean()` when the user asks to remove expired sessions.
4. On a new machine, install `ffmpeg`, install the engine, and run `transcribe doctor`.

## Decision rules

- Language is always automatic; there is no language parameter.
- The model is fixed: 4-bit whisper-large-v3-turbo (`mlx-community/whisper-large-v3-turbo-4bit`) on MLX, Apple Silicon only.
- Do not upload audio or use a cloud fallback.
- If the engine is missing or misbehaving, run `transcribe doctor`, then `transcribe restart`.
- Live sessions expire after one hour; generated file transcripts after seven days.
