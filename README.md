# Transcribe Leggerissimo

Dictation and file transcription for macOS 26, on Apple's on-device speech stack.
One small app. Nothing to install.

| Measured on an M4, warm | |
|---|---|
| Paste fires after key-up | **58–105 ms** (p50) |
| 4-minute audio file → transcript | **4,200 ms** — RTF **0.0176×** |
| Entire app | **0.6 MB** |
| Download | **one ~250 KB zip** |
| Setup after drag-to-Applications | **none** |

No models. No Python. No ffmpeg. No server.

## How it works

- Press **^Space** (configurable), speak, press again — the transcript pastes into whatever
  app you are in. The recognizer runs while you speak, so only ~60–105 ms of work remains
  at key-up.
- Drop any WAV/AIFF/CAF/M4A file on the menu-bar mic (or use the Finder Quick Action) and a
  `<file>.md` transcript appears next to it.
- Language is set once in the menu (**Language**): Auto, en, it, de, es regional variants.
  Auto runs two recognizers on your audio and keeps the one that commits text (~4 ms cost).
- Sessions land in `~/Library/Application Support/transcribe/sessions/` — live recordings for
  1 hour, file transcripts for 7 days, swept automatically.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon |
| macOS | 26 or newer |
| Downloads | none — no models, no Python, no ffmpeg |

## Install

1. Download `Transcribe-<version>.zip` from [Releases](https://github.com/gbrlpzz/transcribe/releases).
2. Unzip, drag **Transcribe.app** into `/Applications`, open it.
3. Approve Microphone and Speech Recognition once when asked.

## CLI

The app binary *is* the CLI. Optional, so agents and scripts can call it by name:

```bash
sudo ln -sf /Applications/Transcribe.app/Contents/MacOS/Transcribe /usr/local/bin/transcribe

transcribe file notes.m4a --json   # {"file","text","language","elapsed_ms","md_path"}
transcribe languages               # readiness matrix
transcribe languages --install it-IT
transcribe doctor --json
```

Exit codes: `0` ok · `2` usage · `3` unreadable file · `4` language not ready · `5` transcription failed.
There is no server and no port.

## Agent skill

`skill/transcribe/SKILL.md` is a plain markdown skill wrapping the CLI — copy-paste usable by
any agent. Install with `bash scripts/install-skill.sh`.

## Build from source

```bash
make app        # → app/dist/Transcribe.app
make dist       # → release zip for a GitHub release
swift test      # cd app; 50-case executable battery + dictbench latency harness
```

## Privacy

On-device only. No analytics, no network except the manual update check. Details:
[docs/PRIVACY.md](docs/PRIVACY.md). Behavior notes on Apple's speech APIs:
[docs/APPLE-SPEECH-API-NOTES.md](docs/APPLE-SPEECH-API-NOTES.md).

## License

Apache-2.0 — see [LICENSE](LICENSE).
