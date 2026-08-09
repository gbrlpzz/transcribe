# Troubleshooting

## `transcribe doctor` is your first step

```bash
transcribe doctor
```

It checks ffmpeg, the transcription backend, the microphone device, and the
Accessibility permission needed for pasting.

## Common issues

### "no transcription backend installed"
Install a backend into the environment where `transcribe` is installed:

```bash
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe     --with mlx-whisper            # Apple Silicon
# or
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe     --with faster-whisper         # Intel Mac / Linux
```

### Pasting does nothing
Pasting sends a synthetic Cmd+V, which macOS restricts. Grant **Accessibility**
to your terminal (CLI) or to Transcribe (app):
System Settings → Privacy & Security → Accessibility.

Workaround: `transcribe config set paste false` — text is then copied to the
clipboard instead of pasted.

### The menu-bar app says "Engine not found"
The app looks for the `transcribe` binary in `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin`, and `PATH`. Install it with
`uv tool install transcribe` (after `uv tool install --from …`, above).

### First dictation is slow / downloads for minutes
The first run downloads the model (~1.6 GB for `large-v3-turbo`). Subsequent
dictations are warm and fast. Pre-download any model ahead of time with:

```bash
huggingface-cli download mlx-community/whisper-large-v3-turbo
```

### Microphone permission was denied
System Settings → Privacy & Security → Microphone → enable Transcribe (app) or
your terminal (CLI), then restart the recording.

### "Nothing Heard"
Speak closer to the mic, check the input device in System Settings → Sound →
Input, or set a specific device: `transcribe config set device 1` (see
`ffmpeg -f avfoundation -list_devices true -i ""`).

### Smart text replaces words you meant literally
Smart text only rewrites whole-word tokens ("comma", "period", "new line",
…). If it still misfires for your use case:
`transcribe config set smart_text false`.

### Where is everything stored?
`~/Library/Application Support/transcribe/` — config, sessions (audio +
transcripts, wiped after 48 h), and model cache under `~/.cache/huggingface`.
