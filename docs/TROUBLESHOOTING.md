# Troubleshooting

## Check the installation

Run:

```bash
transcribe doctor
```

The command checks the local engine, the selected backend, `ffmpeg`, the model cache, and macOS permissions.

## The engine is offline

Start it from the menu-bar app by choosing **Engine: not running — Start**. You can also run:

```bash
transcribe serve
```

The server listens only on `127.0.0.1:8765`.

## The first request is slow

The first request downloads the model weights. The default `turbo-q4` download is about 450 MB, plus about 80 MB for the language-detection helper, and happens once. Later requests use the local cache.

Check the model cache:

```bash
transcribe models
du -sh ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-4bit
```

Do not start a second engine process on port `8765`. If an old process is still listening, restart the menu-bar app or stop that process before starting the server manually.

## Transcription fails with an MLX stream error

MLX GPU streams belong to the thread that created them. The current server warms the model and runs inference on one dedicated engine thread. Restart the engine after upgrading MLX:

```bash
pkill -f 'transcribe serve --port 8765'
transcribe serve --port 8765
```

If the error continues, reinstall the supported tool environment and keep the tested MLX versions:

```bash
uv tool install --force --from git+https://github.com/gbrlpzz/transcribe transcribe --with mlx==0.32.1 --with mlx-whisper==0.4.3
```

## Finder does not show the Quick Action

Reinstall it:

```bash
make quick-action-install
```

Then open Finder, select a file, and choose **Quick Actions → Transcribe**. The service accepts all files. Transcription succeeds when the local `ffmpeg` build can find and decode an audio stream.

## The source file disappeared

The app sends `preserve_source: true` for Finder and menu-bar file jobs. The source should remain in its original folder. The transcript is saved beside it as `<file>.md`.

If the source is still moved, verify that the installed app is current:

```bash
make app-install
```

## Paste does not work

Run:

```bash
transcribe doctor
```

Enable Accessibility for Transcribe in **System Settings → Privacy & Security → Accessibility**. The app opens this page when setup is incomplete.

## The HUD looks stuck

A long file can take time. The file spinner stays visible while the engine works. The live recorder can run at the same time, but final model requests share one warm engine and may wait for the current request.

Use **Esc** or click the active HUD to cancel the live or file job.

## Clean old sessions

Sessions are stored under:

```text
~/Library/Application Support/transcribe/sessions/
```

Remove expired data:

```bash
transcribe clean
```

Live sessions use the one-hour TTL. Generated file transcripts use the seven-day TTL. This does not remove the active model cache or Finder source files.
