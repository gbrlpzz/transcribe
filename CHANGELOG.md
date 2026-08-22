# Changelog

## 0.5.0 — lean pass (unreleased)

One model, one backend, automatic language: everything else deleted.

- Removed the faster-whisper fallback and Intel support; MLX on Apple Silicon is the only path.
- Removed model selection (`turbo`, `turbo-q8` profiles and the `models` command); the release ships only 4-bit whisper-turbo.
- Removed language controls everywhere; language is detected automatically per utterance with whisper-tiny.
- `config.json` shrunk to hotkey, port, and retention settings; unknown legacy keys are ignored.
- New CLI engine controls: `transcribe start`, `stop`, `restart`.
- Menu-bar menu trimmed to Dictate, Transcribe File…, engine status/start-restart, Sessions Folder, About, Quit.
- Engine-ready polling four times faster (0.25 s) so cold starts feel instant.
- New menu-bar controls: engine status row (click to start/restart) and
  `Check for Updates…`, which installs a published release zip and refreshes
  the engine automatically.
- About shows the release version.
- Menu items no longer advertise keyboard chords; the global hotkey stays the
  single way to dictate.
- Engine restarts are faster: model snapshots resolve from the local cache
  without a network round-trip (stop->warm measured 1.7 s -> 0.8 s).
- Removed dead surfaces: unused URL scheme, `listen` alias, legacy storage
  compatibility, empty bench directory.
- Fixed stale app bundle version string.
- File-job `.md` transcripts are written by the engine itself, so a finished job always produces its file even if the requesting app restarted or timed out.
- The engine answers `503 engine busy` immediately instead of silently queueing; dictation requests time out after 90 s, file jobs after 30 min.
