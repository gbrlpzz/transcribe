# Transcribe

Dictation and file transcription for macOS 26, on Apple's on-device speech
stack. 529,840 bytes. No models, no Python, no ffmpeg, no server.

Measured on an M4, warm: paste fires 58–105 ms after key-up (p50 58 ms). A
4-minute file transcribes in 4,200 ms — RTF 0.0176×.

## Use

- **^Space** (configurable): dictate; the transcript pastes into the focused
  app. The capsule pill rides below the notch — a live waveform while you
  speak, "Transcribing…" while it thinks, a green check when done. Click or
  Esc cancels.
- Drop a WAV/AIFF/CAF/M4A on the menu-bar mic (or Finder Quick Action): a
  `<file>.md` transcript appears beside it.
- **Language** menu: Auto, or any language this Mac's speech stack offers.
  Auto listens for your first three macOS languages at once (System
  Settings › General › Language & Region) and writes down whichever is
  spoken — sentence by sentence, so a dictation or recording may change
  language midway. Pin a language to switch that off.
- **Vocabulary**: names and jargon it keeps misspelling go in
  `~/Library/Application Support/transcribe/config.json`, spelled the way
  they should come out: `"vocabulary": ["Gabriele Pizzi", "Kubernetes"]`.
  Near-misses it was unsure of are rewritten; words it heard clearly are
  left alone.
- **Nothing persists.** A dictation lives in your clipboard; a file
  transcript lives in the `.md` beside the audio. The app forgets the rest.

## Install

Unzip, drag `Transcribe.app` to /Applications. Apple Silicon, macOS 26+.
Releases: https://github.com/gbrlpzz/transcribe/releases

## CLI

The app binary is the CLI — one command:

    sudo ln -sf /Applications/Transcribe.app/Contents/MacOS/Transcribe /usr/local/bin/transcribe

    transcribe notes.m4a --json
    # {"file","text","language","elapsed_ms","md_path"}
    transcribe talk.m4a --locale de-DE   # one language only

Without `--locale` it is Auto, as above; `language` then lists what was
spoken, in order: `"en-US,de-DE"`.

Missing language assets install automatically. Exit codes: 0 ok · 2 usage ·
3 unreadable file · 4 language not ready · 5 failed.

## Build

    make app     # app/dist/Transcribe.app
    make dist    # release zip
    make test    # test battery (dictbench latency harness lives beside it)

## Privacy

On-device. No analytics; network only for the update check at launch,
which installs a newer release by itself.
docs/PRIVACY.md · docs/APPLE-SPEECH-API-NOTES.md · docs/TROUBLESHOOTING.md

## License

MIT — see LICENSE. Copyright (c) 2026 Gabriele Pizzi
