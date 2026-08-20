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

The menu-bar app removes its temporary microphone WAV after transcription. The engine removes expired session records according to `cleanup_ttl_hours`, which defaults to 48 hours.

Finder and menu-bar file transcription preserve the selected source file. Finder output is written as `<file>.md` beside the source. The source is not moved into the session folder.

Run cleanup manually:

```bash
transcribe clean
```

Set the TTL to zero to remove session data after completion:

```bash
transcribe config set cleanup_ttl_hours 0
```

## macOS permissions

- **Microphone**: Used while dictation is recording.
- **Accessibility**: Used to paste text into the focused app. If it is unavailable, the result is still copied to the pasteboard.
- **Apple Events**: Used by the paste operation to send `⌘V`.
