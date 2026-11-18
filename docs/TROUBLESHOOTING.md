# Troubleshooting

## Dictation does nothing / no text appears

1. System Settings → Privacy & Security → **Microphone** → allow Transcribe.
2. System Settings → Privacy & Security → **Speech Recognition** → allow Transcribe.
   Without this the recognizer produces no output at all — the app checks both before every
   session and shows an alert if denied.

## Paste does not happen

System Settings → Privacy & Security → **Accessibility** → allow Transcribe (the menu shows
**Enable Accessibility to Paste…** while it is missing). Until then the transcript is copied
to the clipboard instead of pasted.

After updating from 1.3.1 or earlier the switch can look on and still not work: releases
changed signing certificate in 1.3.2, and macOS keeps the old entry. Remove Transcribe from
the Accessibility list (−) and add it again.

## A language is not ready

Language assets are delivered by macOS. Picking a language in the **Language** menu and
dictating, or transcribing a file with `transcribe <file> --locale it-IT`, asks macOS to
install it. You can also add the language under System Settings → Keyboard → **Dictation**.

Installs are OS-managed and can take minutes. If one stalls, the app gives up after 120 s
instead of waiting forever (the CLI exits 4) — try again later.

## A dropped file produces nothing

File jobs fail quietly: no `.md` appears and the pill just goes away. The reason is in the
log (`log show --last 5m --predicate 'process == "Transcribe"'`), or run the same file through
the CLI, which prints the error and exits 3 (unreadable), 4 (language) or 5 (failed).

## Hotkey conflict

If ^Space is taken by another app, Transcribe says so at launch. Change the hotkey in
`~/Library/Application Support/transcribe/config.json` (`"hotkey": "ctrl+option+space"`),
then relaunch the app.

## Reinstall / reset permissions

```bash
tccutil reset Microphone com.gbrlpzz.transcribe
tccutil reset SpeechRecognition com.gbrlpzz.transcribe
tccutil reset Accessibility com.gbrlpzz.transcribe
```

Then relaunch the app and approve the prompts again.
