# Changelog

## 0.6.0 — diet engine + honesty pass (unreleased)

Measured vs 0.5.0 on Apple M4, macOS 26.2 (August 2026). Methods in
`.work/reports/` of the repo at build time; every number below is from an
actual run.

| Area | 0.5.0 | 0.6.0 | Delta |
|---|---|---|---|
| Tool install size | 1.02 GB | ~248 MB fresh venv (`du -sk`) | −76% |
| Engine cold import (`import mlx_whisper`) | ~620–730 ms | ~122–142 ms steady | −~0.5 s |
| Dictation fixed paste delay | +120 ms every utterance | deleted | −120 ms |
| ffmpeg decodes per dictation utterance | 2 (~31 ms each) | 0 (PCM read in-process) | −~31–62 ms per utterance |
| Short-utterance E2E (HTTP) | 1.02 s median | TBD(gates): re-bench on merged engine | coordinator fills before publish |
| Engine memory idle-warm | ~1.0 GB physical footprint | ~1.0 GB (unchanged; weights dominate) | honest wording replaces "<0.9 GB" claim |
| Language detection honesty | claimed ~25 ms | measured 58.8–61.1 ms, docs corrected | truth |
| Release zip junk | 14 `__MACOSX/` entries | 0 entries (23 → 9 zip entries) | clean |
| Repo weight | +208 KB committed icon artifacts | deleted (regenerable via one script) | hygiene |
| App code | DictationPill switch duplication | TODO(merge): exact LOC delta from app wave (~−300 Swift) | simpler |

- **Diet engine**: the runtime now uses
  [mlx-whisper-diet](https://github.com/gbrlpzz/mlx-whisper-diet), our public
  slim drop-in fork of mlx-whisper 0.4.3 (same `mlx_whisper` module). It drops
  torch (dead code upstream: nothing imported it) and makes numba/scipy
  optional extras only needed for word timestamps. Same transcripts on the
  default path — verified token-identical output against stock 0.4.3.
- **Dictation path**: the app no longer sleeps 120 ms before pasting, and the
  engine hands decoded PCM to mlx-whisper directly instead of shelling out to
  ffmpeg twice per utterance. ffmpeg is no longer required for dictation or
  WAV file jobs; it stays optional for other media containers.
- **Docs honesty**: language detection documented at its measured ~60 ms (was
  claimed ~25 ms); memory documented as ~1.0 GB physical footprint idle,
  ~1.7 GB peak (the old "<0.9 GB" held only for process RSS); model download
  total stated precisely (~520 MB).
- **Hygiene**: release zips are built without Finder `__MACOSX/` metadata;
  regenerable icon artifacts (208 KB) removed from the repo.

## 0.5.0 — lean pass

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
