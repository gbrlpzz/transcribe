# Changelog

All notable changes to Transcribe are documented here.

## [0.5.0] - 2026-08-21

The Zig rewrite of the dictation hot path. Everything latency-critical moves
into a resident, zero-config daemon; the Python engine keeps only the model.

Measured on the reference machine (9 s speech clip, turbo-q4 warm):

| Metric | 0.4.0 | 0.5.0 |
|---|---|---|
| Capture start overhead per press | ~219 ms (ffmpeg spawn) | ~0 ms (resident unit) |
| First text visible | after full decode (~1.1 s after key-up) | during speech (first partial ~5.8 s into a 9 s clip, at the first sentence pause) |
| Paste path | pbcopy + osascript subprocesses (~97 ms) | CGEvent direct (~1 ms) |
| Hot-path processes per press | python + ffmpeg + pbcopy + osascript | none (daemon already resident) |
| Daemon binary footprint | — | ~500 KB, no runtime deps |

### Added

- `daemon/`: `transcribed`, a Zig capture daemon. Carbon global hotkey
  (control+space), Core Audio capture with an s16le/16 kHz client format
  (AUHAL converts; the render callback commits straight into a lock-free
  ring), Unix-socket streaming client, and native CGEvent paste.
- `transcribe/streamserver.py`: streaming endpoint for the warm engine.
  Energy VAD gates silence, speech decodes in chunks (≥1.5 s plus a ≥320 ms
  pause, or a 4 s cap) so partial text arrives while speaking, and repeated
  words at chunk seams are deduped. Protocol v1 is documented in
  `docs/DAEMON.md`.
- `bench/bench_streaming.py`: whole-file vs streaming latency benchmark;
  results in `bench/results/streaming.json`.
- Dev commands: `transcribed once` (timed mic session) and `transcribed pipe`
  (replay a wav through the full pipeline).

### Changed

- Dictation is zero-config: language is always auto-detected per utterance,
  the hotkey and socket path are fixed, and no settings surface exists in the
  daemon. The menu-bar app is no longer part of the dictation path (it stays
  available as legacy); file transcription remains on the Finder Quick Action.

## [0.4.0] - 2026-08-21

Performance release. Goal: fastest possible transcription with the lowest
footprint, so the engine can run next to any heavy workload. UI and UX are
untouched.

Measured on the same machine, best of 3, word error rate against known text:

| Metric | 0.3.1 (fp16 turbo) | 0.4.0 (q4 turbo + tiny LID) |
|---|---|---|
| Short dictation (~6 s clip) | ~1.9–2.0 s | **~1.1 s** |
| Long file IT/EN (48 s) | 3.5–3.9 s | **2.4–2.6 s** |
| Engine process RAM | ~2.1 GB | **~0.8 GB, bounded** |
| Model weights in memory | 1543 MB fp16 | **452 MB 4-bit** |
| Language detection per utterance | ~0.9 s | **~25 ms** |

### Changed

- Default model profile is now `turbo-q4` (4-bit). Identical accuracy to fp16
  in benchmarks (0% WER English, 0.8% Italian), ~12% faster decode, weights
  3.4× smaller. `turbo-q8` and fp16 stay selectable; existing configs migrate
  automatically.
- Per-utterance language detection now runs on a warm `whisper-tiny` helper
  (~20–90 ms) instead of the main model's full 30-second encoder pass (~0.9 s).
  Mixed Italian↔English dictation still switches utterance by utterance, with
  fallback to full detection at low confidence.
- MLX reusable GPU buffers are capped at 256 MiB (`mx.set_cache_limit`). Idle
  memory drops to weights-only; long jobs can no longer grow unbounded.
- The engine sweeps expired data every 30 minutes while running
  (`cleanup_interval_minutes`). TTLs are unchanged: live sessions 1 h,
  generated file transcripts 7 d.
- Pinned `mlx==0.32.1`.

### Fixed

- Model-holder eviction: warming the tiny detector used to evict the main
  model from mlx-whisper's shared holder, silently reloading all weights from
  disk on every utterance. Direct references keep both models warm;
  `/health` reports warm state correctly.

### Rejected alternative (documented for future decisions)

- Parakeet v3 was benchmarked as a different architecture: faster on some
  clips (0.23 s short EN), but ~3% worse Italian WER and ~2.1 GB RAM. Not
  adopted; 4-bit turbo keeps accuracy first.

## [0.3.1] - 2026-08-20

### Added

- Finder and the native file picker now accept any file. Local `ffmpeg` decides whether it contains a supported audio stream.
- Live clipboard text is cleared after a one-hour recovery window when it has not been replaced.
- Live sessions and generated file transcripts now have separate retention windows.

### Changed

- Live audio and metadata expire after one hour by default.
- Generated file Markdown and session metadata expire after seven days by default. Original file sources are never removed.
- Decoder errors now include the local `ffmpeg` reason.

### Fixed

- File transcript cleanup now removes generated Markdown as well as session metadata.
- Sessions remain cleanable when transcript text retention is disabled.

## [0.3.0] - 2026-08-20

### Added

- Concurrent live and Finder file transcription feedback in the notch HUD.
- Separate cancellation and completion states for live and file jobs.
- Native macOS spinner for indeterminate file transcription progress.
- Cold-launch file handoff and queued open-file events.

### Changed

- Keep one tested `whisper-turbo` model profile to reduce memory pressure and avoid untested model switches.
- Run MLX warm-up and inference on one dedicated engine thread.
- Preserve Finder source files and write Markdown output beside them.
- Use native macOS open-file events for the Finder Quick Action.
- Updated documentation to match the tested release profile.

### Fixed

- MLX GPU stream errors caused by warm-up and inference running on different threads.
- Finder Quick Action file type metadata and cold-launch delivery.
- Duplicate server cleanup when a second engine tries to use an occupied port.

## [0.2.1] - 2026-08-19

### Fixed

- Restored reliable second `⌃␣` tap behavior: it stops recording and starts transcription.
- Restored the pre-release Escape monitor path so Escape cancellation does not interfere with the dictation hotkey.

## [0.2.0] - 2026-08-19

### Added

- Finder Quick Action for audio and video files.
- Native file transcription with Markdown output beside the source and clipboard copy.
- Start and completion notifications for background file transcription.
- Capsule-shaped HUD shadow and corrected notch/menu-bar placement.
- Cancellation for file transcription with request-token protection against late responses.

### Changed

- Escape is consumed only while recording or transcribing, using a Carbon hotkey with a session event-tap fallback.
- Reuse the transcription backend across multi-file CLI jobs and warm the model before the first request.
- Skip redundant ffmpeg normalization for native 16 kHz mono PCM WAV recordings.
- Stop the HUD waveform timer when the HUD is not recording.

### Fixed

- Finder Automator metadata compatibility and Quick Action launcher paths.
- Escape no longer leaks into the focused terminal, IDE, or agent session while transcription is active.
