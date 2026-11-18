---
name: transcribe
description: >
  Local file transcription on a Mac using Transcribe (native Apple speech,
  macOS 26+). Transcribe audio files to text or Markdown — fully on-device,
  no cloud, no server.
---

# Transcribe — local file transcription

Transcribe audio files on this Mac with the `transcribe` CLI. All speech
processing runs on-device through Apple's native speech stack (macOS 26+).
No server, no port, no cloud calls.

## Setup

The CLI is the app binary itself, invoked under the name `transcribe`:

```bash
sudo ln -sf /Applications/Transcribe.app/Contents/MacOS/Transcribe /usr/local/bin/transcribe
```

(The link name must be exactly lowercase `transcribe` — that is what selects
CLI mode inside the single app binary. Any directory on `PATH` works.)

First run may raise two one-time macOS prompts: Speech Recognition permission
(approve once), and per-language voice assets downloaded by the OS on first
use of that language.

## The one command

```bash
transcribe recording.m4a             # prints transcript, writes recording.md beside it
transcribe a.wav b.m4a c.mp3         # sequential, one transcript each
transcribe notes.m4a --json          # machine-readable, one JSON object per line
transcribe talk.m4a --locale de-DE   # force a language (BCP-47 tag)
```

There are no subcommands and no other flags.

Without `--locale` the language is detected: every installed language among
the user's first three macOS languages is listened for, and a recording that
changes language between sentences is followed. Use `--locale` only when the
user names the language or detection got it wrong.

`--json` line shape (keys sorted):

```json
{"elapsed_ms": 1710, "file": "notes.m4a", "language": "en-US", "md_path": "/path/notes.md", "text": "..."}
```

`language` lists the languages in the transcript in order of first
appearance, comma-separated: `"en-US"`, or `"en-US,de-DE"` for a mixed file.

Every run writes `<name>.md` next to each file, replacing one that is already
there. Nothing else is stored anywhere.

Supported containers (read natively by macOS, no ffmpeg): WAV, AIFF, CAF,
m4a/AAC, MP3. Exotic containers (mkv, webm) are rejected with exit code 3.

## Exit codes

With several files, the exit code is the worst one.

| code | meaning |
|---|---|
| 0 | success |
| 2 | usage error (unknown flag, no input files) |
| 3 | file error (missing/unreadable/unsupported container) |
| 4 | language unsupported, or its assets did not become ready |
| 5 | transcription failure (incl. denied Speech Recognition permission) |

## Decision rules

- Language: use `--locale <ll-CC>` when the user names a language; otherwise
  let it detect.
- Names and jargon that come out misspelled: add them to the `"vocabulary"`
  array in `~/Library/Application Support/transcribe/config.json`, spelled
  correctly, and run again.
- A language that is not installed yet is installed automatically on first
  use; that can take minutes and gives up after a 120 s stall (exit 4). Retry
  once, then tell the user to add the language under System Settings ›
  Keyboard › Dictation.
- No model selection exists — Apple owns models and updates.
- Do not upload audio anywhere or suggest cloud services.
- Long files are fast: expect well under real-time (240 s ≈ 4 s on Apple Silicon).
