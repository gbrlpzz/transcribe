# Transcribe

**Fully local, native macOS dictation and transcription — with a first-class Prime Agent skill.** Hold a global hotkey anywhere, speak, and on-device Whisper types your words into the focused app — a free, private commercial dictation software alternative for everyone, and Prime Agent can dictate and transcribe files with the same local engine. Audio and transcripts are wiped automatically; nothing ever leaves your Mac.

```
┌─────────────────────────────┐     ┌──────────────────────────┐
│  menu-bar app (Swift)       │     │  Prime Agent skill       │
│  global hotkey · mic · paste│     │  transcribe_audio()      │
└──────────────┬──────────────┘     └─────────────┬────────────┘
               │  WAV (16 kHz)                    │  audio file
               ▼                                  ▼
        ┌───────────────────────────────────────────────┐
        │  local engine server  (127.0.0.1:8765)         │
        │  Whisper large-v3-turbo · MLX (Apple Silicon)  │
        │  faster-whisper fallback · smart text · TTL    │
        │  cleanup of sessions (default 48 h)            │
        └───────────────────────────────────────────────┘
```

## Why

- **Private** — Whisper runs entirely on your Mac. No cloud, no API keys, no subscription, no audio uploads.
- **Accurate** — `whisper-large-v3-turbo` by default: near-large-v3 accuracy at several times real-time on Apple Silicon, with English + Italian (and 90+ languages) auto-detected.
- **Native** — a real macOS menu-bar app: press-and-hold to talk, release to insert, exactly like commercial dictation software. Built with AppKit + Carbon, following Apple Human Interface Guidelines.
- **Prime Agent–ready** — ships as an installable agent skill: Prime Agent can dictate and transcribe files with the same local engine, no cloud fallback. Use it standalone, with Prime Agent, or both.
- **Self-cleaning** — every recording and transcript lives in a session folder and is wiped after the TTL (default 48 h, configurable). No bloat, ever.

## Install

Requires macOS 14+, [Homebrew](https://brew.sh), and an Apple Silicon Mac for the default engine (Intel Macs use the faster-whisper fallback).

```bash
# 1. engine + CLI (one command)
brew install ffmpeg
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe

# 2. native menu-bar app
git clone https://github.com/gbrlpzz/transcribe.git && cd transcribe
make app-install          # builds and copies Transcribe.app to /Applications

# 3. first-run checks
transcribe doctor

# 4. optional — Prime Agent skill (only if you use Prime Agent)
bash <(curl -fsSL https://raw.githubusercontent.com/gbrlpzz/transcribe/main/scripts/install-skill.sh)
```

The first dictation downloads the model (~1.6 GB) from Hugging Face into the
local cache; after that everything works offline.

> On a fresh install, macOS asks for **Microphone** access (first recording)
> and **Accessibility** access (to paste). The menu-bar app guides you through
> both.

## Use it

### Menu-bar app (dictation-style)

Launch **Transcribe** (Spotlight → Transcribe). A mic icon appears in the menu bar.

- **Hold `⌃␣`** (Control+Space), speak, release → text is pasted into whatever app is focused.
- A floating black **audio pill** appears below the notch: a live waveform while recording, a spinner while transcribing, and a text preview when done — then it fades away on its own.
- Click the menu-bar icon for **Model** / **Language** choices, **Transcribe File…**, and **Clean Up Old Recordings**.

### CLI

```bash
transcribe                 # press Enter to start/stop recording → transcribes + pastes
transcribe file notes.m4a  # transcribe an existing file (prints the text)
transcribe file a.m4a b.mp3 --language it
transcribe serve           # run the local engine server (the app does this automatically)
transcribe clean           # wipe sessions older than the TTL
transcribe config set language it
transcribe models          # list models and installed backends
transcribe doctor          # diagnose the setup
transcribe app build       # build the native app from source
```

### Prime Agent (optional)

The skill makes dictation and transcription first-class agent capabilities — the same local engine, no cloud fallback:

```python
import transcribe_skill

result = await transcribe_skill.transcribe_audio("meeting.m4a")
print(result["text"], result["language"], result["model"])

await transcribe_skill.dictate()          # records until you press Enter
await transcribe_skill.clean()            # enforce the TTL cleanup now
```

## Models

| Alias | Size | Languages | Notes |
|---|---|---|---|
| `large-v3-turbo` *(default)* | ~1.6 GB | multilingual | best accuracy/speed balance |
| `large-v3` | ~3 GB | multilingual | maximum accuracy, slower |
| `medium` | ~1.5 GB | multilingual | lighter |
| `small` | ~470 MB | multilingual | lightest multilingual |
| `turbo` | ~800 MB | English only | fastest |

`transcribe config set model large-v3` (or pick it in the app menu). Backends:
`mlx-whisper` on Apple Silicon, `faster-whisper` everywhere else. See
[docs/MODELS.md](docs/MODELS.md).

## Privacy & cleanup

- Transcription runs **entirely on-device**; the engine server binds to `127.0.0.1`.
- Recordings + transcripts are stored under `~/Library/Application Support/transcribe/sessions/` and **deleted automatically after 48 h** (`cleanup_ttl_hours`, `transcribe clean` runs on every command and server start).
- The menu-bar app deletes each temp recording immediately after transcription.

See [docs/PRIVACY.md](docs/PRIVACY.md).

## Configuration

`~/Library/Application Support/transcribe/config.json` — edited with
`transcribe config set KEY VALUE` or in the app menu:

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

## Development

```bash
make venv        # create .venv, install package + dev deps
make test        # unit tests
make app         # build the menu-bar app
make doctor      # diagnose
```

Layout:

```
transcribe/   Python engine: audio capture, Whisper backends, smart text,
                    session storage, localhost server, CLI
app/                native menu-bar app (Swift, AppKit + Carbon)
skill/              Prime Agent skill (SKILL.md + transcribe_skill.py)
docs/               architecture, privacy, models, troubleshooting
```

## Roadmap

- [ ] Silero VAD for auto-segmenting long recordings
- [ ] Optional LLM smart-formatting pass (dictation-style commands)
- [ ] Live transcription preview window
- [ ] `launch at login` toggle (SMAppService)

## License

MIT — see [LICENSE](LICENSE). Runtime dependencies: [mlx-whisper](https://github.com/ml-explore/mlx-examples), [faster-whisper](https://github.com/SYSTRAN/faster-whisper) — see [NOTICE](NOTICE).
