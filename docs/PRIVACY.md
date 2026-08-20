# Privacy and data retention

Transcribe runs locally. Speech recognition and file processing happen on the Mac.

## Local processing

- The engine listens only on `127.0.0.1:8765`.
- Audio is not sent to a cloud service.
- There is no analytics or tracking code.
- The model is downloaded once from the model registry. After that, inference works offline.

## Stored data

Microphone dictation creates a temporary WAV file and a session record under:

```text
~/Library/Application Support/transcribe/sessions/YYYYMMDD/
```

A session can contain:

- The temporary WAV recording.
- The transcript and metadata in a JSON file.

The menu-bar app removes its temporary microphone WAV after transcription. The engine keeps the moved live WAV and its metadata for `live_cleanup_ttl_hours` (one hour by default), then removes both. The live clipboard value is also cleared after one hour when it has not been replaced by the user.

Finder and menu-bar file transcription preserve the selected source file. Finder output is written as `<file>.md` beside the source. The source is not moved into the session folder. The generated Markdown and session metadata are removed after `cleanup_ttl_hours` (seven days by default).


Run cleanup manually:

```bash
transcribe clean
```

Set the live recovery window and file retention separately:

```bash
transcribe config set live_cleanup_ttl_hours 1
transcribe config set cleanup_ttl_hours 168
```

Use `transcribe clean` to remove data that has passed either TTL. Setting a TTL to `0` removes that class on the next cleanup run.

## macOS permissions

- **Microphone**: Used while dictation is recording.
- **Accessibility**: Used to paste text into the focused app. If it is unavailable, the result is still copied to the pasteboard.
- **Apple Events**: Used by the paste operation to send `⌘V`.
