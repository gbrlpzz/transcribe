# Troubleshooting

## Check the installation

Run:

```bash
transcribe doctor
transcribe ping
```

The commands check the local engine, backend, `ffmpeg`, model cache, and the
live Unix socket.

## The engine is offline

The engine and daemon start through LaunchAgents after `make install`. To
reload the complete installation:

```bash
bash scripts/install-macos.sh
```

For a foreground engine test:

```bash
transcribe serve --no-warm
```

The HTTP server listens only on `127.0.0.1:8765`. The streaming socket is:

```text
~/Library/Application Support/transcribe/dictation.sock
```

Do not start a second engine process on port `8765` while the LaunchAgent is
running.

## The first request is slow

The first install downloads the model weights. The default `turbo-q4`
download is about 450 MB, plus about 80 MB for the language-detection helper.
The daemon also prepares Core Audio once at startup. On the reference machine
that preparation took about 1.998 s once; later activation measured 31–38 ms.

Check the model cache:

```bash
transcribe models
du -sh ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-4bit
```

## Transcription fails with an MLX stream error

MLX GPU streams belong to the thread that created them. The current server
warms the model and runs inference on one dedicated engine thread. Reload the
installation after upgrading MLX:

```bash
bash scripts/install-macos.sh
```

The supported Apple Silicon versions are `mlx==0.32.1` and
`mlx-whisper==0.4.3`.

## The shortcut does not work

The primary shortcut is `⌃␣`. If macOS reserves it for input-source switching,
the daemon automatically tries `⌃⌥␣`. Grant Accessibility and Input Monitoring
to:

```text
~/.local/bin/transcribe
```

Then reload the daemon:

```bash
launchctl kickstart -k gui/$(id -u)/com.gbrlpzz.transcribe.daemon
```

## Finder does not show the Quick Action

Reinstall it:

```bash
make quick-action-install
```

Then open Finder, select a file, and choose **Quick Actions → Transcribe**.
The service accepts a file when the local `ffmpeg` build can decode an audio
stream.

## Paste does not work

Run:

```bash
transcribe doctor
```

Enable Accessibility for `~/.local/bin/transcribe` in **System Settings →
Privacy & Security → Accessibility**. The final text remains available through
the local engine even when paste permission is missing.

## Clean old sessions

Sessions are stored under:

```text
~/Library/Application Support/transcribe/sessions/
```

Remove expired data:

```bash
transcribe clean
```

Live sessions use the one-hour TTL. Generated file transcripts use the
seven-day TTL. This does not remove the model cache or Finder source files.
