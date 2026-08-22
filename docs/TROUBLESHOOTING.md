# Troubleshooting

First stop: `transcribe doctor` (or drag the app binary to a terminal and run it).
It reports macOS version, speech-stack availability, permission states, and per-language readiness.

## Dictation does nothing / no text appears

1. System Settings → Privacy & Security → **Microphone** → allow Transcribe.
2. System Settings → Privacy & Security → **Speech Recognition** → allow Transcribe.
   Without this the recognizer produces no output at all — the app checks both before every
   session and shows an alert if denied.

## Paste does not happen

System Settings → Privacy & Security → **Accessibility** → allow Transcribe. Until then the
transcript is copied to the clipboard instead of pasted.

## A language shows NOT READY

Language assets are delivered by macOS. Either add the language under
System Settings → Keyboard → **Dictation**, or run:

```bash
transcribe languages --install it-IT
```

Installs are OS-managed and can take minutes. If one stalls at 0%, the app fails fast with
guidance instead of waiting — retry after a system update.

## Hotkey conflict

If ^Space is taken by another app, Transcribe says so at launch. Change the hotkey in
`~/Library/Application Support/transcribe/config.json` (`"hotkey": "ctrl+option+space"`),
then restart the app.

## Sessions disk usage

Live recordings expire after one hour, file transcripts after seven days. Current data:
open the menu → **Sessions Folder…**.

## Reinstall / reset permissions

```bash
tccutil reset Microphone com.gbrlpzz.transcribe
tccutil reset SpeechRecognition com.gbrlpzz.transcribe
tccutil reset Accessibility com.gbrlpzz.transcribe
```

Then relaunch the app and approve the prompts again.
