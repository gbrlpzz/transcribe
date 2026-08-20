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
        │  One warm Whisper turbo model · MLX           │
        │  Local storage · smart text · TTL cleanup     │
        └───────────────────────────────────────────────┘
```

## Features

- **Local and private**: Speech recognition runs on the Mac. The engine binds to `127.0.0.1`.
- **One tested model**: `whisper-turbo` stays warm for reliable dictation and file transcription.
- **Native menu-bar app**: Global hotkey, paste support, microphone recording, and setup checks.
- **Notch HUD**: Apple-style status feedback with recording, transcription, result, error, and cancel states.
- **Concurrent feedback**: Live dictation and file transcription have separate HUD states. A file is a large pill alone. During overlap, live dictation is on the left and the file is a spinner circle on the right.
- **Finder Quick Action**: Transcribe any file with an audio stream that the local `ffmpeg` build can decode. The source file stays in place and `<file>.md` is saved beside it.
- **Prime Agent skill**: Optional local transcription tools for Prime Agent.
- **Automatic cleanup**: Live audio and pasted text are kept for a one-hour recovery window. Generated file transcripts are kept for seven days by default. Selected source files are never deleted.

## Requirements

| Component | Minimum | Recommended |
|---|---|---|
| Mac | Apple Silicon M1+ or Intel Mac | Apple Silicon |
| Memory | 8 GB | 16 GB or more |
| macOS | 14.0 | Latest supported macOS |
| Storage | About 3 GB | 5 GB free |
| Tools | `uv`, `ffmpeg` | Homebrew, `uv`, `ffmpeg` |

### Model and memory

Transcribe keeps one `whisper-turbo` model warm. The model weights use about 1.6 GB on disk. A clean-process test on a 16 GB Apple Silicon Mac used about 2.6 GB physical memory for a 51-second file. Long files can use more working memory.

The app uses the MLX backend on Apple Silicon. The `faster-whisper` backend remains available for Intel Macs and other systems.

## Installation

Install `ffmpeg` and the local engine:

```bash
brew install ffmpeg
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe --with mlx==0.32.0 --with mlx-whisper==0.4.3
```

For Intel Macs or other systems without MLX:

```bash
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe --with faster-whisper
```

Build and install the menu-bar app:

```bash
git clone https://github.com/gbrlpzz/transcribe.git
cd transcribe
make app-install
```

Install the Finder Quick Action:

```bash
make quick-action-install
```

Optional Prime Agent skill:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gbrlpzz/transcribe/main/scripts/install-skill.sh)
```

The first run downloads the model to `~/.cache/huggingface/hub/`. Later runs work offline. macOS asks for Microphone and Accessibility access on first use.

## Usage

### Menu-bar app

Launch `/Applications/Transcribe.app`. A microphone icon appears in the menu bar.

- Press `⌃␣` to start dictation.
- Press `⌃␣` again to stop and transcribe.
- Press `Esc` or click the HUD to cancel.
- Use **Transcribe File…** to choose any media file with an audio track. `ffmpeg` handles the container and codec.
- Use **Clean Up Old Recordings** to remove sessions older than the TTL.

The result is pasted into the focused app. File transcription also writes a Markdown file beside the source.

### Finder Quick Action

Right-click any file in Finder and choose **Quick Actions → Transcribe**. Files without a decodable audio stream fail with the local `ffmpeg` reason. The source stays in its original folder. The transcript is written beside it as `<file>.md`.

### Command line

```bash
# Dictate from the terminal
transcribe

# Transcribe files
transcribe file meeting.m4a
transcribe file interview.mp3 notes.wav --language it

# Run or inspect the local engine
transcribe serve
transcribe doctor
transcribe models

# Clean expired live data and file transcripts
transcribe clean

# Change local settings
transcribe config set language en
transcribe config set hotkey "ctrl+space"
transcribe config set live_cleanup_ttl_hours 1
transcribe config set cleanup_ttl_hours 168
```

### Prime Agent skill

```python
import transcribe_skill

result = await transcribe_skill.transcribe_audio("interview.m4a")
print(result["text"])
print(result["language"])

await transcribe_skill.dictate()
await transcribe_skill.clean()
```

## Configuration

Configuration is stored at `~/Library/Application Support/transcribe/config.json`:

```json
{
  "model": "turbo",
  "language": "auto",
  "backend": "auto",
  "paste": true,
  "smart_text": true,
  "live_cleanup_ttl_hours": 1.0,
  "cleanup_ttl_hours": 168.0,
  "hotkey": "ctrl+space",
  "port": 8765
}
```

The release profile uses the tested `turbo` model and one warm engine process. The engine accepts a raw model repository path for development, but other model profiles are not part of the supported app configuration.

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
├── app/               # Native macOS menu-bar app
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

## License

MIT. See [NOTICE](NOTICE) for third-party runtime and model attributions.
