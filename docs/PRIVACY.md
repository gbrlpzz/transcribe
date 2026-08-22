# Privacy and data retention

Transcribe runs locally. Speech recognition and file processing happen on the Mac,
through Apple's on-device speech stack.

## Local processing

- Audio is not sent to a cloud service.
- There is no analytics or tracking code.
- Language assets are delivered by macOS itself; after they are present, inference works offline.
- The only network access in the app is the manual **Check for Updates…** menu item.

## Stored data

Dictation creates a session under:

```text
~/Library/Application Support/transcribe/sessions/YYYYMMDD/
```

A session contains the recording WAV and a JSON metadata file with the transcript.

- Live dictation data is kept for `live_cleanup_ttl_hours` (one hour by default), then removed.
- Finder and menu-bar file transcription keep the source file in place and write `<file>.md`
  beside it. The generated Markdown and session metadata are removed after `cleanup_ttl_hours`
  (seven days by default).
- The clipboard value is cleared after one hour when it has not been replaced by the user.

Run cleanup manually:

```bash
transcribe clean --dry-run   # preview
```

TTLs are set in `~/Library/Application Support/transcribe/config.json`
(`live_cleanup_ttl_hours`, `cleanup_ttl_hours`).

## macOS permissions

- **Microphone**: used while dictation records.
- **Speech Recognition**: on-device transcription of your audio.
- **Accessibility**: used to paste text into the focused app. If unavailable, the result is copied to the pasteboard instead.
- **Apple Events**: sends the paste `⌘V`.
