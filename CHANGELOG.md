# Changelog

All notable changes to Transcribe are documented here.

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
