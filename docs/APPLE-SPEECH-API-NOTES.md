# Apple SpeechAnalyzer / SpeechTranscriber — field notes (macOS 26)

Verified behaviors from building Transcribe Leggerissimo 1.0. Kept public because this API
is new and thinly documented. Test machine: Apple Silicon, macOS 26.x, Xcode CLT.

## Audio contract

- Manual-feed analyzers accept exactly {16 kHz, 8 kHz} × mono × signed-int16 interleaved.
  Feeding anything else trips a hard precondition crash — not catchable. Convert with
  `AVAudioConverter`; check `availableCompatibleAudioFormats` first.
- Buffer size is free (4k–48k frames identical RTF). File input via
  `SpeechAnalyzer(inputAudioFile:finishAfterFile:true)` converts internally and reads
  WAV/AIFF/CAF/m4a-AAC/MP3 without ffmpeg.

## Results and finalization

- `.progressiveTranscription` emits volatile revisions + committed finals; finals only are
  safe to accumulate (240 s of speech ≈ 1100 volatiles / ~27 finals).
- Ending input alone emits nothing. Call `finalizeAndFinishThroughEndOfInput()` — measured
  flush 58–232 ms depending on tail. Text extraction: `String(result.text.characters)`
  (`AttributedString` is not string-convertible).

## Readiness truth (the big trap)

- An uninstalled locale fails SILENTLY: `availableCompatibleAudioFormats` is just empty.
  That empty/non-empty probe is the ONLY reliable readiness test.
- NEVER gate on `AssetInventory.installedLocales`, `.installed`, or `.supported` — all three
  list locales that cannot actually run.
- `AssetInstallationRequest.downloadAndInstall()` can hang at 0% forever with no error.
  Wrap installs in a stall watchdog (~120 s) and never block a user interaction on them.

## Concurrency

- One input sequence per analyzer; a second sequence on a live analyzer crashes.
- Keep a strong reference until result streams close — dropping mid-analysis is a trap.
- Multiple analyzers run concurrently with negligible contention (~5–6 MB per task);
  use `Options(priority: .userInitiated)` so dictation is not starved by file jobs.

## Locale management

- Canonicalize with `SpeechTranscriber.supportedLocale(equivalentTo:)`; compare BCP-47 lowercased.
- Reserve via `reserve(locale:)` (async, throws); budget is small (5) — reserve primaries,
  release LRU on `tooManyAssetLocalesAllocated` (err 11); err 10 re-reserve + retry;
  err 15 = unsupported, hide from picker.
