# Privacy and data retention

Transcribe runs locally. Speech recognition and file processing happen on the Mac,
through Apple's on-device speech stack.

## Local processing

- Audio is not sent to a cloud service.
- There is no analytics or tracking code.
- Language assets are delivered by macOS itself; after they are present, inference works offline.
  In Auto, the app asks macOS for the assets of your first three system languages at launch.
- The only network access in the app is the update check: at every launch it asks the GitHub
  releases API for the latest version and, when one is newer, downloads that release and
  replaces itself. Nothing about you or your audio is sent.

## Stored data

Nothing is archived. No recordings, no session history, no transcript log.

- **Dictation**: audio is streamed to the recognizer in memory and never written to disk. The
  transcript goes to the clipboard and is pasted. The clipboard value is cleared after one
  hour if you have not replaced it — and the timer does not survive quitting the app.
- **Files**: the source file stays where it is and `<file>.md` is written beside it. That
  Markdown file is yours; the app never deletes it.
- **Settings**: `~/Library/Application Support/transcribe/config.json` holds the hotkey, the
  chosen language and your vocabulary list.

## macOS permissions

- **Microphone**: used while dictation records.
- **Speech Recognition**: on-device transcription of your audio.
- **Accessibility**: used to paste text into the focused app (a synthetic ⌘V) and to hear Esc
  while recording. If unavailable, the result is copied to the clipboard instead.
