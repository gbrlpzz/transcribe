# Transcribe

**Local dictation and audio transcription for macOS.** Press a global hotkey, speak, and Transcribe types the result into the focused app. Audio stays on your Mac.

```
┌─────────────────────────────┐     ┌──────────────────────────┐
│  Menu-bar App (Swift)       │     │  Prime Agent Skill       │
│  Global hotkey · Mic · HUD  │     │  transcribe_audio()      │
└──────────────┬──────────────┘     └─────────────┬────────────┘
               │  WAV (16 kHz mono)               │  Audio file
               ▼                                  ▼
        ┌───────────────────────────────────────────────┐
        │  Local Engine Server (127.0.0.1:8765)         │
        │  One warm Whisper turbo-q4 model · MLX        │
        │  Local storage · smart text · TTL cleanup     │
        └───────────────────────────────────────────────┘
```

## Features

- **Local and private**: Speech recognition runs on the Mac. The engine binds to `127.0.0.1`.
- **One model, zero choices**: 4-bit `whisper-turbo` (`turbo-q4`) stays warm for fast, low-footprint dictation and file transcription. Language is detected automatically per utterance — mixed Italian/English just works.
- **Native menu-bar app**: Global hotkey, paste into any app, microphone recording, and a one-row engine status you can click to start or restart.
- **Notch HUD**: Apple-style status feedback with recording, transcription, result, error, and cancel states.
- **Self-updating**: **Check for Updates…** installs the newest GitHub release and refreshes the engine.
- **Finder Quick Action**: Right-click any file with an audio stream and transcribe it. The source file stays in place and `<file>.md` is saved beside it.
- **Prime Agent skill**: Optional local transcription tools for Prime Agent.
- **Automatic cleanup**: Live audio is kept for a one-hour recovery window, generated file transcripts for seven days. The engine sweeps expired data every 30 minutes while it runs.

## Requirements

| Component | Minimum |
|---|---|
| Mac | Apple Silicon (M1 or newer) |
| macOS | 14.0 |
| Storage | About 3 GB free |
| Tools | [`uv`](https://docs.astral.sh/uv/), `ffmpeg` (`brew install ffmpeg`) |

### Model and memory

Transcribe keeps exactly one model warm: the 4-bit `whisper-large-v3-turbo` conversion (`turbo-q4`, about 450 MB of memory). The engine caps its reusable GPU cache at 256 MB, so the whole engine stays under about 0.9 GB.

Language detection uses a tiny helper model (whisper-tiny, about 80 MB) per utterance — about 25 ms — so dictation results typically return in about one second for short utterances with no language setup.

Benchmarks on an M4 showed identical accuracy to full-precision weights (0% word error rate on English, 0.8% on Italian samples) at roughly 12% faster decode. See [docs/MODELS.md](docs/MODELS.md).

## Installation

Install `ffmpeg` and the local engine:

```bash
brew install ffmpeg
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe
```

Build and install the menu-bar app:

```bash
git clone https://github.com/gbrlpzz/transcribe.git
cd transcribe
make app-install
```

Optional Prime Agent skill:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gbrlpzz/transcribe/main/scripts/install-skill.sh)
```

The first run downloads the models to `~/.cache/huggingface/hub/`. Later runs work offline. macOS asks for Microphone and Accessibility access on first use.

## Usage

### Menu-bar app

Launch `/Applications/Transcribe.app`. A microphone icon appears in the menu bar.

- Press `⌃␣` to start dictation.
- Press `⌃␣` again to stop and transcribe.
- Press `Esc` or click the HUD to cancel.
- Use **Transcribe File…** to choose any media file with an audio track.
- The **Engine** row shows whether the engine is running; click it to start or restart it.

The result is pasted into the focused app. File transcription also writes a Markdown file beside the source.

### Finder Quick Action

Right-click any file in Finder and choose **Quick Actions → Transcribe**. The source stays in its original folder; the transcript is written beside it as `<file>.md`.

### Command line

```bash
# Dictate from the terminal
transcribe

# Control the background engine
transcribe start
transcribe stop
transcribe restart

# Transcribe files
transcribe file meeting.m4a interview.mp3

# Run or inspect the engine
transcribe serve      # foreground, what the app spawns
transcribe doctor

# Clean expired live data and file transcripts
transcribe clean

# Change local settings
transcribe config set hotkey "ctrl+option+space"
transcribe config set cleanup_ttl_hours 168
```

### Prime Agent skill

```python
import transcribe_skill

result = await transcribe_skill.transcribe_audio("interview.m4a")
print(result["text"])

await transcribe_skill.dictate()
await transcribe_skill.clean()
```

## Configuration

One model, one language mode (auto), one backend — there is nothing to choose. The remaining settings live at `~/Library/Application Support/transcribe/config.json`:

```json
{
  "hotkey": "ctrl+space",
  "port": 8765,
  "live_cleanup_ttl_hours": 1.0,
  "cleanup_ttl_hours": 168.0,
  "cleanup_interval_minutes": 30.0,
  "keep_transcripts": true
}
```

Unknown keys from older releases are ignored on load.

## Privacy and storage

1. Speech recognition runs locally.
2. The HTTP server listens only on `127.0.0.1`.
3. Sessions are stored under `~/Library/Application Support/transcribe/sessions/`.
4. Live session audio and metadata expire after `live_cleanup_ttl_hours` (one hour by default).
5. The live clipboard value is cleared after the same recovery window if it is unchanged.
6. Generated file Markdown and metadata expire after `cleanup_ttl_hours` (seven days by default).
7. Finder source files are preserved. Cleanup never removes them.

See [docs/PRIVACY.md](docs/PRIVACY.md).

## Repository structure

```
transcribe/
├── app/               # Native macOS menu-bar app (Swift)
├── transcribe/        # Local Python engine, CLI, server, and storage
├── skill/             # Optional Prime Agent skill
├── docs/              # Architecture, privacy, model, and troubleshooting docs
├── tests/             # Python tests
├── Makefile           # Build, test, and install commands
└── pyproject.toml     # Python package metadata
```

## Development

```bash
make venv
make test
make app
make app-install
make doctor
```

### Releasing

1. Bump the version in `pyproject.toml`, `transcribe/__init__.py`,
   `tests/test_engine.py`, and `app/Resources/Info.plist`
   (`CFBundleShortVersionString` and `CFBundleVersion`).
2. Update `CHANGELOG.md`.
3. `make test && make dist` — this builds the app and produces
   `release/Transcribe-<version>.zip`.
4. Commit, tag `v<version>`, push, and publish a GitHub release with the zip
   attached. The app's **Check for Updates…** item finds it by tag and asset.

## License

MIT. See [NOTICE](NOTICE) for third-party runtime and model attributions.
