---
name: transcribe
description: >
  Local file transcription on a Mac using Transcribe (native Apple speech,
  macOS 26+). Transcribe audio files to text or Markdown, check setup, and
  manage language assets — fully on-device, no cloud, no server.
---

# Transcribe — local file transcription

Transcribe audio files on this Mac with the `transcribe` CLI. All speech
processing runs on-device through Apple's native speech stack (macOS 26+).
No server, no port, no cloud calls.

## Setup

The CLI lives inside the app bundle:

```bash
TRANSCRIBE_APP="${TRANSCRIBE_APP:-/Applications/Transcribe.app}"
CLI="$TRANSCRIBE_APP/Contents/MacOS/transcribe"
```

Optional one-time setup so any shell can call `transcribe` directly:

```bash
ln -sf "$TRANSCRIBE_APP/Contents/MacOS/Transcribe" /usr/local/bin/transcribe
```

(The symlink name must be exactly lowercase `transcribe` — that is what
selects CLI mode inside the single app binary.)

First run may raise two one-time macOS prompts: Speech Recognition permission
(approve once), and per-language voice assets downloaded by the OS on first
use of that language.

## Commands

### Check setup

```bash
"$CLI" doctor
"$CLI" doctor --json        # machine-readable
```

Reports macOS version, speech-stack availability, microphone + speech
recognition permission, accessibility, app-bundle presence, and which
languages are ready.

### List languages / install language assets

```bash
"$CLI" languages            # readiness matrix
"$CLI" languages --json
"$CLI" languages --install it-IT   # fetch Apple language assets (progress on stderr)
```

Shipped set: English (`en-*`), Italian (`it-*`), German (`de-DE/AT/CH`),
Spanish (`es-ES/MX/US`). A locale must be `ready` before files in it can be
transcribed; installs can take minutes and are OS-managed after that.

### Transcribe files

```bash
"$CLI" file recording.m4a             # prints transcript, writes recording.md beside it
"$CLI" file a.wav b.m4a c.mp3         # sequential, one transcript each
"$CLI" file notes.m4a --json          # machine-readable, one JSON object per line
"$CLI" file talk.m4a --locale de-DE   # force a language (BCP-47 tag)
"$CLI" file secret.wav --no-keep      # stdout only: no .md sidecar, no session record
```

`--json` line shape (keys sorted):

```json
{"elapsed_ms": 1710, "file": "notes.m4a", "language": "en-US", "md_path": "/path/notes.md", "text": "..."}
```

`md_path` is `""` under `--no-keep`. Without it, the transcript is also saved
as `<name>.md` next to each file and archived in the sessions folder
(`~/Library/Application Support/transcribe/sessions/<YYYYMMDD>/`; live data is
cleaned up automatically after 1 hour, file transcripts after 7 days).

Supported containers (read natively by macOS, no ffmpeg): WAV, AIFF, CAF,
m4a/AAC, MP3. Exotic containers (mkv, webm) are rejected with exit code 3.

## Exit codes

| code | meaning |
|---|---|
| 0 | success |
| 2 | usage error (unknown command/flag; there is no `serve`) |
| 3 | file error (missing/unreadable/unsupported container) |
| 4 | locale not ready or unsupported (`transcribe doctor`, then `languages --install <locale>`) |
| 5 | transcription failure (incl. denied Speech Recognition permission) |

## Decision rules

- Language: use `--locale <ll-CC>` when the user names a language;
  otherwise the configured default or auto-detection from system settings.
- No model selection exists — Apple owns models and updates.
- Do not upload audio anywhere or suggest cloud services.
- If something fails: run `doctor --json`, fix what it flags, retry once.
- Long files are fast: expect well under real-time (240 s ≈ 4 s on Apple Silicon).
