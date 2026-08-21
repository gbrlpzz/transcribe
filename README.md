# Transcribe

**Local dictation and audio transcription for macOS.** Press a global hotkey, speak, and Transcribe types the result into the focused app. Audio stays on your Mac.

```text
┌──────────────────────────────┐        ┌─────────────────────────────┐
│  transcribe (Zig, resident)  │  UDS   │  Local engine (Python/MLX)   │
│  hotkey · Core Audio · paste │ ─────► │  warm turbo-q4 · VAD · text  │
└──────────────┬───────────────┘        └──────────────┬──────────────┘
               │                                        │
               │ Finder Quick Action                    │ local files
               ▼                                        ▼
          selected audio/video ────────────────► Markdown beside source
```

## Features

- **Local and private**: Speech recognition runs on the Mac. The engine binds to `127.0.0.1`.
- **One tested model**: 4-bit `whisper-turbo` stays warm for fast, low-footprint dictation and file transcription.
- **Zig capture daemon (v0.5.1)**: A resident ~500 KB binary owns the hotkey, microphone, streaming transport, and paste. Text streams in while you speak; no ffmpeg or Python startup on the hot path. See [docs/DAEMON.md](docs/DAEMON.md).
- **Finder Quick Action**: Transcribe any file with an audio stream that the local `ffmpeg` build can decode. The source file stays in place and `<file>.md` is saved beside it.
- **Prime Agent skill**: Optional local transcription tools for Prime Agent.
- **Automatic cleanup**: Live audio and pasted text are kept for a one-hour recovery window. Generated file transcripts are kept for seven days by default. Selected source files are never deleted. The engine sweeps expired data every 30 minutes while it runs, so storage stays bounded between restarts.

## Requirements

| Component | Minimum | Recommended |
|---|---|---|
| Mac | Apple Silicon M1+ or Intel Mac | Apple Silicon |
| Memory | 8 GB | 16 GB or more |
| macOS | 14.0 | Latest supported macOS |
| Storage | About 3 GB | 5 GB free |
| Tools | `uv`, `zig`, `ffmpeg` | Homebrew, `uv`, `zig`, `ffmpeg` |

### Model and memory

Transcribe keeps one quantized `whisper-turbo` model warm (`turbo-q4`, 4-bit). The model weights use about 450 MB of memory, and the engine caps its reusable GPU cache at 256 MB, so the whole engine stays under about 0.9 GB — small enough to run next to heavy workloads.

This footprint is a deliberate design constraint, not just a model-selection side effect. Transcribe is intended to remain resident all day alongside editors, browsers, development tools, and other memory-intensive work. The default engine therefore optimizes for the combined cost of **latency, memory, disk footprint, and transcription quality**, rather than maximum inference throughput in isolation. Larger or faster ASR stacks can win raw realtime-factor benchmarks, but that trade is not automatically useful for short interactive dictation once transcription is already comfortably faster than realtime.

The practical target is a small warm engine with negligible activation overhead and fast enough inference that dictation feels immediate, without reserving several gigabytes of unified memory for an occasional foreground action. Alternative engines may be reconsidered when they improve the overall latency/footprint/quality tradeoff, rather than speed alone.

Language detection uses a tiny helper model (about 80 MB) per utterance. This keeps automatic Italian/English switching fast: dictation results typically return in about one second for short utterances, with no fixed-language setup.

A clean-process test on a 16 GB Apple Silicon Mac transcribed a 48-second file in about 2.4–2.6 seconds. Benchmarks showed identical accuracy to full-precision weights (0% word error rate on English, 0.8% on Italian samples).

The engine uses the MLX backend on Apple Silicon. The `faster-whisper` backend remains available for Intel Macs and other systems.

## Installation

The supported install path is one command on macOS:

```bash
brew install uv ffmpeg zig
git clone https://github.com/gbrlpzz/transcribe.git
cd transcribe
make install
```

`make install`:

- installs the Python/MLX engine as the private `transcribe-engine` command;
- builds and installs the Zig `transcribe` command;
- installs the Finder Quick Action;
- starts both local LaunchAgents at login;
- installs the optional Prime Agent skill.

The public command is always `transcribe`. The engine command is private and
normally does not need to be called directly. The first run needs Microphone,
Accessibility, and (for the event-tap fallback) Input Monitoring permission
for `~/.local/bin/transcribe`.

For Intel Macs or systems without MLX, `make install` selects
`faster-whisper` automatically. The first run downloads the model to
`~/.cache/huggingface/hub/`; later runs work offline.

To install only the Finder action:

```bash
make quick-action-install
```

## Usage

### Dictation

The daemon starts automatically after `make install`. You can also start it
in the foreground:

```bash
transcribe run
```

Press `⌃␣`. Press it again to stop. The result is pasted into the focused app.
If macOS reserves `⌃␣`, the daemon automatically uses `⌃⌥␣`. Partial text
arrives while you speak.

Useful checks:

```bash
transcribe --version
transcribe doctor
transcribe ping
```

### Finder Quick Action

Right-click any file in Finder and choose **Quick Actions → Transcribe**.
The source stays in place. The transcript is written beside it as `<file>.md`.

### Command line

```bash
transcribe file meeting.m4a
transcribe file interview.mp3 notes.wav --language it
transcribe serve                 # private engine server, normally automatic
transcribe models
transcribe clean
```

`transcribe` is the single public command. File and engine commands are
forwarded internally to `transcribe-engine`; users do not need to manage two
commands.

### Prime Agent skill

```python
import transcribe_skill
result = await transcribe_skill.transcribe_audio("interview.m4a")
print(result["text"])
```

## Performance

The daemon warms the Core Audio unit once at startup. On the reference Apple
Silicon Mac this warm-up took about **1.998 s once**. Each later activation
measured **31–38 ms**, compared with about **219 ms** for the legacy ffmpeg
startup path. These are measured values, not estimates.

The daemon prints fast timings at the finest available clock precision. For
example, a sub-millisecond value is shown as microseconds or nanoseconds. The
streaming protocol also carries the raw `elapsed_ns` value so future
optimizations do not lose precision through millisecond rounding.

## Configuration

Configuration is stored at `~/Library/Application Support/transcribe/config.json`:

```json
{
  "model": "turbo-q4",
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

The release profile uses `turbo-q4` and one warm engine process. The daemon
always uses automatic language detection. Its shortcut is fixed and its
socket is fixed at `~/Library/Application Support/transcribe/dictation.sock`;
those are not user settings.

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
├── daemon/            # Native Zig capture daemon and public transcribe binary
├── transcribe/        # Private Python engine, CLI, server, and storage
├── skill/             # Optional Prime Agent skill
├── docs/              # Architecture, daemon, privacy, model, troubleshooting
├── bench/             # Reproducible performance benchmarks and results
├── tests/             # Python tests
├── Makefile           # Build, test, and install commands
└── pyproject.toml     # Python package metadata
```

## Development

```bash
make venv
make test
make daemon-test
make daemon
make doctor
```

## License

MIT. See [NOTICE](NOTICE) for third-party runtime and model attributions.
