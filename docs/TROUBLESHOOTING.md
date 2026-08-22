# Troubleshooting

## Check the installation

Run:

```bash
transcribe doctor
```

The command checks the engine, `mlx-whisper`, the microphone, Accessibility permissions, stale sessions, and `ffmpeg` availability.
`ffmpeg` is needed for media files that are not WAV/PCM and for dictating from the terminal; menu-bar-app dictation and WAV files work without it.

## The engine is offline

Start or restart it from the CLI:

```bash
transcribe start    # starts the background engine
transcribe restart  # stop + start, use after any hiccup
```

You can also click **Engine: not running — Start** in the menu-bar app, or run it in the foreground with `transcribe serve`. The server listens only on `127.0.0.1:8765`.

## The first request is slow

The first run downloads the model weights: about 450 MB for `turbo-q4` plus about 71 MB for the language-detection helper (roughly 520 MB total). This happens once; later requests use the local cache.

Check the model cache:

```bash
du -sh ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-4bit
```

Do not start a second engine process on port `8765`. If an old process is still listening, run `transcribe restart`.

## Transcription fails with an MLX stream error

MLX GPU streams belong to the thread that created them. The server warms the model and runs inference on one dedicated engine thread. Restart the engine after upgrading MLX:

```bash
transcribe restart
```

If the error continues, reinstall the supported tool environment with the tested MLX versions:

```bash
uv tool install --force --from git+https://github.com/gbrlpzz/transcribe transcribe
```

## Finder does not show the Quick Action

Reinstall it:

```bash
make quick-action-install
```

Then open Finder, select a file, and choose **Quick Actions → Transcribe**. The service accepts all files. WAV files transcribe without extra tools; any other container needs a local `ffmpeg` build that can find and decode its audio stream.

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

Enable Accessibility for Transcribe in **System Settings → Privacy & Security → Accessibility**. The app opens this page when setup is incomplete. Until then, results are left on the pasteboard so you can paste manually.

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
