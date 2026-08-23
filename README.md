# Transcribe

Dictation and file transcription for macOS 26, on Apple's on-device speech
stack. 565,152 bytes. No models, no Python, no ffmpeg, no server.

Measured on an M4, warm: paste fires 58–105 ms after key-up (p50 58 ms). A
4-minute file transcribes in 4,200 ms — RTF 0.0176×.

## Use

- **^Space** (configurable): dictate; the transcript pastes into the focused
  app. The HUD tetrahedron spins while recording, tumbles reversed while
  transcribing, locks still when done. Click or Esc cancels.
- Drop a WAV/AIFF/CAF/M4A on the menu-bar mic (or Finder Quick Action): a
  `<file>.md` transcript appears beside it.
- **Language** menu: Auto, or any language this Mac's speech stack offers.
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

Missing language assets install automatically. Exit codes: 0 ok · 2 usage ·
3 unreadable file · 4 language not ready · 5 failed.

## Build

    make app     # app/dist/Transcribe.app
    make dist    # release zip
    make test    # 32-case battery + dictbench latency harness

## Privacy

On-device. No analytics; network only for the manual update check.
docs/PRIVACY.md · docs/APPLE-SPEECH-API-NOTES.md · docs/TROUBLESHOOTING.md

## License

Apache-2.0 — see LICENSE.
