# Transcribe

**Local dictation and audio transcription for macOS — with a Prime Agent skill.** Tap a global hotkey, speak, and tap again. Whisper runs on your Mac and types your words into the focused app. Audio files and transcripts are wiped automatically after 48 hours. Nothing leaves your machine.

```
┌─────────────────────────────┐     ┌──────────────────────────┐
│  Menu-bar App (Swift)       │     │  Prime Agent Skill       │
│  Global hotkey · Mic · HUD  │     │  transcribe_audio()      │
└──────────────┬──────────────┘     └─────────────┬────────────┘
               │  WAV (16 kHz mono)               │  Audio file
               ▼                                  ▼
        ┌───────────────────────────────────────────────┐
        │  Local Engine Server (127.0.0.1:8765)         │
        │  Whisper large-v3-turbo · MLX (Apple Silicon) │
        │  faster-whisper fallback · Smart text · TTL   │
        │  Automatic session cleanup (default: 48 h)    │
        └───────────────────────────────────────────────┘
```

## Features

- **100% Private**: Whisper runs on-device. No cloud APIs, no telemetry, no subscriptions, no accounts.
- **Accurate**: `whisper-large-v3-turbo` by default. Multilingual (English, Italian, and 90+ languages auto-detected).
- **Apple HIG Notch HUD**: Floating obsidian frosted-glass capsule anchored dead-center under the MacBook notch or menu bar. Features a 60 FPS live waveform visualizer, pulsing recording beacon, undulating loading dots, and semantic status transitions.
- **Tap-to-Toggle**: Tap `⌃␣` (Control+Space) once to start speaking, tap again to finish. No awkward press-and-hold.
- **Prime Agent Skill**: Ships with an installable agent skill so Prime Agent can transcribe files and dictate locally without cloud fallbacks.
- **Self-Cleaning**: Every audio recording and transcript is stored in a session folder and deleted automatically after the configured TTL (default: 48 hours).

---

## System Requirements

| Component | Minimum | Recommended |
|---|---|---|
| **Mac Model** | Apple Silicon (M1+) or Intel Mac (x86_64) | Apple Silicon (M1/M2/M3/M4, Pro, Max, Ultra) |
| **Unified Memory / RAM** | 8 GB | 16 GB or more |
| **Operating System** | macOS 14.0+ (Sonoma or Sequoia) | macOS 14.0+ |
| **Free Storage** | ~3 GB (for engine + default model weights) | 5 GB+ |
| **Tools** | [Homebrew](https://brew.sh), [uv](https://docs.astral.sh/uv/), `ffmpeg` | Homebrew, `uv`, `ffmpeg` |

### Model Memory & Resource Guide

Whisper stays resident in memory so dictation responds in 1–2 seconds. Choose a model that fits your available RAM:

| Model Alias | Disk Size | Active RAM | Processing Speed (MLX) | Recommended Machine |
|---|---|---|---|---|
| `small` | ~470 MB | ~1.0 GB | ~15× real-time | 8 GB RAM machines under heavy multitasking |
| `medium` | ~1.5 GB | ~2.0 GB | ~10× real-time | 8 GB or 16 GB machines |
| `turbo` | ~800 MB | ~1.5 GB | ~12× real-time | English-only fast transcription |
| `large-v3-turbo` *(default)* | ~1.6 GB | ~2.2 GB | ~8× real-time | 8 GB or 16 GB+ machines (best overall) |
| `large-v3` | ~3.0 GB | ~4.5 GB | ~3× real-time | 16 GB+ machines (maximum accuracy) |

---

## Installation

Requires macOS 14+ on an Apple Silicon Mac (or Intel Mac using faster-whisper fallback), and [Homebrew](https://brew.sh).

```bash
# 1. Install ffmpeg and the transcribe engine CLI
brew install ffmpeg
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe

# 2. Build and install the native menu-bar app
git clone https://github.com/gbrlpzz/transcribe.git && cd transcribe
make app-install          # Builds and copies Transcribe.app to /Applications

# 3. Verify setup
transcribe doctor

# 4. (Optional) Install the Prime Agent skill
bash <(curl -fsSL https://raw.githubusercontent.com/gbrlpzz/transcribe/main/scripts/install-skill.sh)
```

The first dictation downloads the default model (~1.6 GB) to `~/.cache/huggingface/`. Subsequent dictations run offline.

> On first launch, macOS will prompt for **Microphone** access (to record audio) and **Accessibility** access (to paste text into active apps).

---

## Usage

### 1. Menu-Bar App

Launch **Transcribe** from Spotlight or `/Applications/Transcribe.app`. A microphone icon appears in the menu bar.

- **Start/Stop Dictation**: Tap `⌃␣` (Control+Space). Speak, then tap `⌃␣` again. The transcribed text is pasted into your active text field.
- **Notch HUD**: While recording, an obsidian glass capsule appears under your screen's notch or menu bar displaying a 60 FPS live audio waveform. It transitions to transcribing dots, displays a checkmark confirmation, and fades away automatically.
- **Menu Bar Controls**: Click the menu-bar icon to switch **Model**, select **Language**, open **Transcribe File…**, or run **Clean Up Old Recordings**.

### 2. Command-Line Interface (CLI)

```bash
# Dictate from terminal (press Enter to start and stop)
transcribe

# Transcribe one or more audio files
transcribe file meeting.m4a
transcribe file interview.mp3 notes.wav --language it

# Start the local engine server manually (the app starts this automatically)
transcribe serve

# Clean up sessions older than the TTL
transcribe clean

# Change configuration settings
transcribe config set model large-v3
transcribe config set language en
transcribe config set hotkey "ctrl+space"
transcribe config set cleanup_ttl_hours 24

# Diagnostics and model information
transcribe doctor
transcribe models
```

### 3. Prime Agent Skill (Optional)

In your Prime Agent session or Python scripts:

```python
import transcribe_skill

# Transcribe an audio recording
result = await transcribe_skill.transcribe_audio("interview.m4a")
print(result["text"])
print(f"Detected language: {result['language']} via {result['model']}")

# Interactive dictation
await transcribe_skill.dictate()

# Trigger session cleanup
await transcribe_skill.clean()
```

---

## Models

| Alias | Size | Languages | Performance | Recommended For |
|---|---|---|---|---|
| `large-v3-turbo` *(default)* | ~1.6 GB | Multilingual | ~8× real-time on MLX | Best overall balance of speed and accuracy |
| `large-v3` | ~3.0 GB | Multilingual | ~3× real-time on MLX | Maximum accuracy for complex audio |
| `medium` | ~1.5 GB | Multilingual | ~10× real-time on MLX | Lightweight multilingual tasks |
| `small` | ~470 MB | Multilingual | ~15× real-time on MLX | Minimal disk and memory footprint |
| `turbo` | ~800 MB | English only | ~12× real-time on MLX | Fastest English-only dictation |

Set your model via `transcribe config set model <alias>` or the app menu. See [docs/MODELS.md](docs/MODELS.md) for details.

---

## Privacy and Storage

1. **Local-Only**: Speech recognition runs entirely on your Mac. The HTTP server binds strictly to `127.0.0.1`.
2. **Session Storage**: Recordings and transcripts are saved to `~/Library/Application Support/transcribe/sessions/YYYYMMDD/<id>.wav` and `.json`.
3. **Auto-Cleanup**: Sessions are permanently deleted after `cleanup_ttl_hours` (default: 48 hours).
4. **Immediate Deletion**: The menu-bar app deletes temporary WAV recordings immediately upon transcription completion. Set `cleanup_ttl_hours 0` to delete all session files immediately.

See [docs/PRIVACY.md](docs/PRIVACY.md) for full details.

---

## Configuration

Configuration is stored at `~/Library/Application Support/transcribe/config.json` and shared between the Swift menu-bar app and Python engine:

```json
{
  "model": "mlx-community/whisper-large-v3-turbo",
  "language": "auto",
  "backend": "auto",
  "paste": true,
  "smart_text": true,
  "cleanup_ttl_hours": 48.0,
  "hotkey": "ctrl+space",
  "port": 8765
}
```

---

## Repository Structure

```
transcribe/
├── app/               # Native Swift menu-bar app (AppKit, Carbon, Notch HUD)
├── transcribe/        # Python engine (MLX Whisper, faster-whisper, storage, CLI, HTTP server)
├── skill/             # Prime Agent skill (transcribe_skill.py, SKILL.md)
├── docs/              # In-depth guides (Architecture, Privacy, Models, Troubleshooting)
├── tests/             # Unit and integration tests
├── Makefile           # Build and test orchestration
└── pyproject.toml     # Python packaging and dependencies
```

---

## Development

```bash
make venv         # Create virtualenv and install dependencies
make test         # Run pytest suite
make app          # Build native Swift app binary (app/dist/Transcribe.app)
make app-install  # Build and install to /Applications/Transcribe.app
make doctor       # Run system diagnostics
```

---

## License

MIT — see [LICENSE](LICENSE). Runtime dependencies: [mlx-whisper](https://github.com/ml-explore/mlx-examples) and [faster-whisper](https://github.com/SYSTRAN/faster-whisper) — see [NOTICE](NOTICE).
