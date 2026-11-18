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

## Several languages at once (1.4.0)

- There is no language identification in the API. Several `SpeechTranscriber`s of different
  locales can share ONE analyzer and one input; each returns its own results.
- Request `attributeOptions: [.audioTimeRange, .transcriptionConfidence]`: every run of a
  result then carries a time range and a 0…1 confidence.
- A transcriber hearing the wrong language still emits fluent-looking text, at confidence
  ≈ 0.3–0.5 against ≈ 0.9+ for the right one. English is the exception: the German and
  Italian models read it at ≈ 0.90 (English model: 0.94) and merely spell it worse, so
  confidence alone picks the wrong lane. `NLLanguageRecognizer` on each lane's own text
  settles it — a German lane that wrote English sentences is not hearing German.
- Word time ranges stretch across silence (a word after a 2 s pause may "start" at the pause),
  and lanes disagree by up to ~0.5 s. Cut between lanes at sentence ends, not at timestamps.
- On audio that changes language, a `.transcription`-preset transcriber commits one long
  final and drops whole sentences of its own language; `.progressiveTranscription` does not.
- Cost: three lanes instead of one moved stop-to-text from 79 to 89 ms (p50) and a 4-minute
  file from 4.0 to 5.6 s.

## Vocabulary

- `AnalysisContext.contextualStrings` has NO effect on `SpeechTranscriber`: identical text
  and identical confidences with and without. `DictationTranscriber` honors it, but its base
  accuracy is clearly lower on the same clip.
- Misheard names come back at confidence ≤ ~0.75; correctly heard ordinary words at ≥ 0.9.
  That gap is enough to correct near-miss spellings after the fact without touching
  "window" when the vocabulary says "Winnow".

## Files

- A zero-length audio file never closes the results stream: the analyzer waits forever.
  Check `AVAudioFile.length` first.

## Locale management

- Canonicalize with `SpeechTranscriber.supportedLocale(equivalentTo:)`; compare BCP-47 lowercased.
- Reserve via `reserve(locale:)` (async, throws); budget is small (5) — reserve primaries,
  release LRU on `tooManyAssetLocalesAllocated` (err 11); err 10 re-reserve + retry;
  err 15 = unsupported, hide from picker.
