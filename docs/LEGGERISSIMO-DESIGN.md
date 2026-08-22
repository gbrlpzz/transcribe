# Transcribe Leggerissimo (v0.7.0) — Native Design Contract

W1 foundation artifact. This is the document the W2 builders code against.
Authority: `.work/REQUIREMENTS.md` R36–R45 (owner directives). Evidence base:
`.work/reports/nat-proto.md` (np), `.work/reports/api-recon.md` (ar),
`.work/reports/wer-kit.md` (accuracy-gate harness). Citation keys:
`np-G1..G12` = nat-proto gotchas log; `ar-§n` = api-recon section.

Status of the Apple speech stack on the reference machine (M4, macOS 26.2):
**GO** (nat-proto verdict) — en-US + de family work end-to-end today;
file RTF 0.0176–0.024 vs MLX 0.29–0.38 (11–21×); first partial at 139 ms cold.
it-IT/es-* assets exist in the catalog but were not delivered on demand
(L-ASSET, np §4) — handled by design in §5.3, not an architecture risk.

---

## 1. Architecture (R37)

One Swift package (`app/Package.swift`, tools 6.2, platform macOS 26 — landed
on this branch in 856979d). Three products from shared sources:

```
Sources/
  TranscribeCore/            NEW library target (shared, no UI)
    SpeechDictationEngine.swift   live lane (§3)
    FileTranscriber.swift         file lane (§4)
    LocaleManager.swift           locale truth + assets (§5)
    SpeechPermissions.swift       TCC ordering (§6)
    SessionStore.swift            sessions + TTL (§7)
    AppConfig.swift               settings storage (§8)   [moved from app target]
    MarkdownWriter.swift          <source>.md writer       [moved]
  Transcribe/                app executable (menu bar, HUD, hotkey, paste)
  transcribe-cli/            CLI executable "transcribe" (§9)
```

The Python engine is retired after parity proof: the 0.6.0 MLX path stays the
running app until gates + owner live-test pass, then the deletions ledger
(§11) executes in W4. There is no hybrid state to ship: the cutover commit is
the one that flips AppDelegate wiring from EngineClient to the native lanes.

## 2. Feature parity lock → design mapping (R36/R36a)

| 0.6.0 feature | Leggerissimo mechanism |
|---|---|
| Global-hotkey dictation | unchanged HotKey + toggle flow; audio path replaced by SpeechDictationEngine (§3) |
| Notch HUD + states | DictationPill states preserved; `.recording` gains optional live text (§10, R41) |
| File transcription + Finder Quick Action | FileTranscriber (§4); workflow hands files to the app unchanged |
| Sessions folder + TTL cleanup | SessionStore, layout-identical (§7) |
| Prime Agent skill | rewritten onto the native CLI (§9, R40) |
| Check for Updates | Updater kept; engine-refresh step deleted (§11) |
| Dictate during long file job (spill lane) | two independent analyzers — concurrency is free (ar CONCURRENCY; conc/conc2 probes: zero contention, ~5–6.5 MB task footprint). The R35 spill-lane machinery has no native counterpart. |

## 3. Live lane — SpeechDictationEngine

New file: `Sources/TranscribeCore/SpeechDictationEngine.swift`.

Pipeline (hotkey-down → hotkey-up):

```
AVAudioEngine.inputNode tap (native hw format)
  → AVAudioConverter → 16 kHz / mono / interleaved Int16      (ar-§2)
  → AnalyzerInput buffers via unbounded AsyncStream            (np-G8)
  → SpeechAnalyzer([SpeechTranscriber(locale, .progressiveTranscription)])
      ├─ volatile results → HUD live text                      (R41, ar-§1a)
      └─ final results     → committed transcript accumulation (np §3)
hotkey-up → finalizeAndFinishThroughEndOfInput() → final text
          → Paste.paste(text)                                  (existing path)
          → async session archive (off the latency path)
```

Design rules, each tied to evidence:

1. **Converter contract**: output exactly 16 kHz mono i16 interleaved. Manual
   feed with anything else crashes (`ar-§3.6`, precondition, not catchable);
   compatible set is only {16k, 8k} × mono × i16 (`np-G7`). The tap runs at
   hardware rate and converts once; converter cost measured negligible
   (`np §1`, AAC 48k resample RTF unchanged).
2. **Manual pump ingestion**, not `analyzeSequence`: slightly faster measured
   (4.23 s vs 5.66 s on 240 s, `np-G9`); buffer granularity free (4k–48k
   identical, `np-G8`) — use whatever the tap delivers.
3. **Preset**: `.progressiveTranscription` = fastResults + volatileResults
   (`ar-§1a`). Punctuation/casing arrive natively without options (live A,
   `ar-§4`). Runtime-only enum cases (singleUtterance, multisegmentResults…)
   do NOT compile against the shipped SDK — never design around them
   (`ar-§1c`).
4. **Text extraction**: `String(result.text.characters)` — AttributedString is
   not LosslessStringConvertible (`np-G5`).
5. **Committed vs volatile**: finals are the only committed prefix; volatiles
   revise the live tail continuously (`np §3`: 1117 volatiles / 27 finals over
   240 s; even the last final beat realtime by 11.4 s). Engine exposes
   `liveText = committed + volatileTail` for the HUD; paste uses finals only.
6. **Finalize semantics**: ending input alone emits nothing final (`np-G2`,
   `ar-§3.4`). Hotkey-up calls `finalizeAndFinishThroughEndOfInput()`;
   measured flush 109–232 ms worst-case-tail, last result already delivered
   when it returns (`ar-§3.4`). This call IS the R38 latency budget target.
7. **One analyzer per session**: a second input sequence on a live analyzer is
   a hard crash (`ar-§3.5`); every dictation builds a fresh analyzer and keeps
   it alive until the results stream closes (`ar-§3.7`, deallocation traps).
8. **Lane priority**: dictation analyzer created with high `Options.priority`
   so a running file job cannot starve finalize (`ar-CONCURRENCY`, IL442).
   R36a acceptance test in §13.
9. **Cancellation**: cancel path calls `cancelAndFinishNow()` (IL224) +
   task cancellation; no orphaned engines/tasks across cycles (§13 AC).
10. **Session persistence**: converted i16 bytes accumulate in memory
    (~190 kB/s); after Paste fires, a WAV (44-byte header + data) is archived
    by SessionStore — replaces Recorder.swift's role and removes the temp-file
    round-trip from the hotkey-up path entirely.
11. **No LID on the live lane**: locale comes from LocaleManager/session
    setting (R42a: performance > code-switching; mixed-language utterances
    need the right session language — documented behavior).

## 4. File lane — FileTranscriber

New file: `Sources/TranscribeCore/FileTranscriber.swift`.

```swift
let analyzer = try SpeechAnalyzer(inputAudioFile: url,
                                 modules: [SpeechTranscriber(locale, .transcription)],
                                 finishAfterFile: true)
// await results; analyzer self-drives; DO NOT also start()/analyzeSequence
// the same file — precondition crash (ar-§3.7). Keep the reference alive.
```

1. Convenience self-driving path (`np §1`: file-mode RTF 0.024 on 240 s;
   manual pump marginally faster but not worth dual code paths here).
2. Preset `.transcription` (no volatile overhead; alternatives/time-indexed
   variants available later if sessions ever need timestamps, `ar-§1a`).
3. Containers: AVAudioFile reads WAV/AIFF/CAF/m4a-AAC/MP3 natively. Session
   WAVs need zero conversion (`np-G7`); AAC 48k verified negligible cost.
   Exotic containers (mkv/webm): visible "unsupported container" error —
   ffmpeg is not bundled and not required (R44).
4. Output `{text, locale, elapsedMs}`; caller writes `<basename>.md` beside
   the source (MarkdownWriter, same naming as engine's
   `write_transcript_markdown`) and archives meta+TTL via SessionStore.
5. Long jobs never block the live lane (independent analyzers, §2/§3.8).

## 5. LocaleManager — asset authority (R42)

New file: `Sources/TranscribeCore/LocaleManager.swift`.

### 5.1 Truth = functional probe
- `status(for:)` builds a `SpeechTranscriber(locale:)` and queries
  `availableCompatibleAudioFormats` / `bestAvailableAudioFormat(compatibleWith:)`.
  Empty/nil ⇒ `.needsInstall`; non-empty ⇒ `.ready`
  (`np-G3`: failure mode is silence, no exception).
- `AssetInventory.installedLocales` is NEVER trusted for gating — it lists
  locales whose modules still report `.supported`, and per-class counts differ
  (`np-G4`, `ar-§5.5`, np-G11: don't gate on `.installed` either).
- Probe results cached at startup; menu/HUD read the cache.

### 5.2 Reservation budget
- `maximumReservedLocales` = 5 (`ar-§5.4`). Our four primary locales (one per
  language: system-matched en variant or en-US; it-IT; de-DE; es-ES) reserve
  at startup — 4 ≤ 5 leaves one slot of headroom.
- A user-picked alternate regional variant (de-AT/de-CH/es-MX/es-US…) reserves
  on demand. On `tooManyAssetLocalesAllocated` (err 11, `ar-§6`): release the
  least-recently-used non-active reservation, retry once.
- Reservation silences the unallocated-locale warning and future-proofs
  against the promised hard error (`ar-§3.8`).

### 5.3 Install flow (L-ASSET-safe)
```
ensureReady(locale):
  status == .ready → return
  request = AssetInventory.assetInstallationRequest(supporting: modules)
  nil → treat as ready-if-formats-appear, else unavailable
  else → Task { try await request.downloadAndInstall() }
         wrapped in stall watchdog (default 120 s, reset on progress change)
         + cooperative cancellation
```
- `downloadAndInstall()` can hang forever with zero error surface (`np-G10`,
  L-ASSET: mobileassetd stalls silently). The watchdog converts that into a
  visible error state with recovery guidance (add the language via
  System Settings › Keyboard › Dictation, which uses the UI-managed download
  path — owner action item from nat-proto).
- Progress: `request.progress` drives HUD/menu percent. Size is opaque until
  transfer starts (totalUnitCount = 1; `np §4`, `ar-§5.3`) — render fraction
  only.
- Error mapping (`ar-§6`): 10 assetLocaleNotAllocated → re-reserve + retry;
  15 cannotAllocateUnsupportedLocale → hide locale from picker;
  16 insufficientResources → fail lane gracefully; 12 timeout → watchdog path.

### 5.4 Shipped set (R42)
en-* / it-IT / de-DE·AT·CH / es-ES·MX·US, all confirmed in
`SpeechTranscriber.supportedLocales`. Picker offers exactly these plus
"Auto (system language)". Default = Auto: resolve the system region locale if
it is in the supported set, else en-US. No code-switching machinery in
v0.7.0 (R42a); mixed-language utterances follow the session language.

## 6. TCC / Info.plist (np-G1)

Landed on this branch (856979d):

- `NSSpeechRecognitionUsageDescription` added next to the existing mic key.
  Without speech-recognition authorization the pipeline emits NOTHING — no
  results, no error, infinite wait (`np-G1`). The key must ship before any
  builder code can prompt.
- `NSMicrophoneUsageDescription` confirmed present (unchanged).
- `LSMinimumSystemVersion` 14.0 → 26.0; Package.swift platforms `.macOS(.v26)`
  (tools 6.2; target pinned to Swift 5 language mode until builders migrate
  their new modules — existing sources compile unchanged).

Authorization ordering (SpeechPermissions.swift, owned by b-dictation):

```
1. AVCaptureDevice.requestAccess(for: .audio)   // mic — existing UX preserved
2. SFSpeechRecognizer.requestAuthorization {}   // speech — BEFORE analyzer creation
3. only then construct/start SpeechAnalyzer
```

Denied speech auth must produce a visible pill error + setup row, never a
silent wait (that silent-stall mode is exactly np-G1). The CLI inherits the
same requirement (§9 doctor reports both statuses; when spawned from inside
Transcribe.app the app's grant covers it).

## 7. SessionStore (parity with 0.6.0 storage.py)

New file: `Sources/TranscribeCore/SessionStore.swift`. Layout identical:

- Root: `~/Library/Application Support/transcribe/sessions/<YYYYMMDD>/`
- ID: `<YYYYmmdd_HHMMSS>_<6 hex>` (matches `_new_id()`)
- Dictation: `<id>.wav` moved into the day dir + `<id>.json` meta
  `{id, created_at, model:"", language, source:"server"|"cli", …}` —
  native writes `model:"apple/<locale>"` (honest label; docs pass owns wording)
- File jobs: source stays in place; `<basename>.md` beside it; meta carries
  `transcript_path`
- TTL sweeper: Timer every 30 min (engine parity); dictation artifacts 1 h
  (`live_cleanup_ttl_hours`), file transcripts 168 h (`cleanup_ttl_hours`) —
  config keys preserved verbatim
- Bookkeeping failures swallowed (never fail a transcription for housekeeping)

## 8. Settings storage

`AppConfig` (Config.swift, moves into TranscribeCore) gains one key:

```swift
var locale: String?   // nil/"auto" = system-language heuristic (§5.4);
                      // otherwise BCP-47, e.g. "it-IT", "de-CH"
```

Unknown keys already ignored by JSONDecoder (upgrades never break). The
`port` key becomes inert at cutover and dies with the deletions ledger.
Menu gains a Language submenu (shipped set + checkmark) writing this key.

## 9. CLI + skill bridge decision (R40)

Decision: **native `transcribe` Swift CLI, embedded in the app bundle. No
HTTP server.** R40 explicitly prefers the CLI if it simplifies — dropping
serve/port/health deletes an entire failure class and matches R44's zero-
package-manager story.

Packaging: new executable target `transcribe-cli` (product name `transcribe`)
linking TranscribeCore; `app/build.sh` copies the binary to
`Transcribe.app/Contents/MacOS/transcribe` (inherits the app signature; TCC
responsibility attributed to the app). The skill calls the absolute in-bundle
path — nothing installed on PATH, nothing to uninstall.

Subcommands (hand-rolled arg parsing, zero dependencies):

| Command | Behavior |
|---|---|
| `file <path>… [--json] [--locale ll-CC] [--no-md]` | sequential transcription; default output human-readable; `--json` = one object per line `{file,text,language,elapsed_ms,md_path}` |
| `doctor [--json]` | macOS ≥26; mic/speech/auth statuses; accessibility; per-locale capability matrix; app-bundle sanity |
| `locales [--json]` | shipped × supported × ready matrix |
| `install-locale <ll-CC>` | trigger asset install; progress lines to stderr |
| `clean [--dry-run]` | TTL sweep, same rules as the app |
| `dictate [--seconds N] [--json]` | mic capture (default 10 s) → transcript; parity insurance for the skill's `dictate()` |

Exit codes: 0 ok · 2 usage · 3 not authorized (message points at doctor) ·
4 transcription failed · 5 locale assets missing/unavailable.

### New Prime Agent skill contract (b-skill-docs rewrites skill/transcribe/SKILL.md)

```bash
TRANSCRIBE_APP="${TRANSCRIBE_APP:-/Applications/Transcribe.app}"
CLI="$TRANSCRIBE_APP/Contents/MacOS/transcribe"
"$CLI" file notes.m4a --json          # transcribe files
"$CLI" dictate --seconds 5 --json     # agent-driven dictation
"$CLI" doctor --json                  # setup diagnosis
"$CLI" locales --json                 # what's ready on this Mac
"$CLI" install-locale it-IT           # fetch Apple language assets
"$CLI" clean --dry-run                # preview TTL cleanup
```

Skill decision rules updated: language via `--locale` or the configured
session default; auto = system-language heuristic; no model selection (Apple
owns models/assets); no server, port, or health endpoint; errors by exit
code; first run on a new Mac may raise the one-time speech-authorization
dialog (approve once). `transcribe_skill.py` + `package.json` deleted (§11).

## 10. Streaming UX (R41)

DictationPill `.recording` gains an associated value:
`.recording(partial: String?)`. Volatile revisions drive a single-line,
tail-truncated label next to the waveform, throttled to ≤10 Hz. Committed
text arrives through the same channel (monotonic prefix growth). Finish →
existing `.flash(success)`; empty → `.flash(empty)`; cancel glide unchanged.
Compact/circle concurrent presentation logic untouched (file job running =
live pill compact left + file circle right, as today).

## 11. Deletions ledger — executes in W4 ONLY, after owner live-test

Parity gates green (incl. R39 WER verdict from `.work/tools/wer/`) + owner
live-test sign-off (R34 discipline) precede ANY deletion. Git history archives
everything (R37: archived, not erased).

Repo removals:
1. `transcribe/` Python package (1529 LOC: cli.py, engine.py, server.py,
   audio.py, storage.py, config.py, __init__.py)
2. `tests/` pytest suite
3. `pyproject.toml`, `transcribe.egg-info/`
4. `skill/transcribe/transcribe_skill.py` + `package.json` (SKILL.md stays, rewritten per §9)
5. Makefile targets `venv install test doctor clean` (+ PYTHON var); Makefile slims to app/app-install/quick-action-install/dist
6. Engine-related `scripts/` members (inventory at execution; install-skill.sh adapts to markdown-only skill)
7. `app/Sources/Transcribe/EngineClient.swift` (HTTP client + engine spawn + PATH probing) and
   `Recorder.swift` (roles absorbed by SpeechDictationEngine tap + SessionStore)
8. Spill-lane server machinery — dies with the package; native dual-lane = two analyzers (ar CONCURRENCY)
9. Updater engine-refresh step (code inside Updater.swift — modify, don't delete the file)
10. ffmpeg references everywhere in the core flow (docs wording per R28)
11. `config.json` `port` key (post-cutover cleanup)

Machine-state cleanup (documented for release notes, not repo changes):
uv tool uninstall; `~/.local/bin/transcribe` shim; optional HF-cache reclaim
(turbo-q4 443 MB + tiny 71 MB ≈ 514 MB); tool venv ≈ 1.02 GB (R18).

Kept: NSMicrophoneUsageDescription, NSAccessibilityUsageDescription,
NSAppleEventsUsageDescription (paste path unchanged), ad-hoc signing story
pending R44a owner pick.

## 12. Performance budgets (R38) — where each is met

| Budget | Mechanism | Evidence today |
|---|---|---|
| hotkey-up → pasted ≤ 150 ms (target) | in-memory buffers, no temp file, finalize→paste direct; lane priority | flush measured 109–232 ms worst-case-tail on file input (ar-§3.4); live-mic expected smaller — gates measure p50/p95 (§13) |
| progressive partials during speech (stretch, R41) | volatileResults preset → HUD label (§10) | first partial 139 ms cold process (np §2) |
| long-file RTF ≤ 0.05× | convenience file path | 0.0176–0.024 measured (np §1) |
| app-driven downloads = 0 | Apple asset system only (LocaleManager §5.3) | asset API probed end-to-end |
| footprint = app bundle | no python/uv/model cache | deletions ledger §11 |

## 13. W2 acceptance criteria (per builder area)

Shared gate for all areas: `swift build` (debug + release) green on the merged
wave branch; no regression from the §14 list; numbers from commands actually
run (rule 5).

### b-dictation — dictation streaming
- AC-D1 (R38): hotkey-up → `Paste.paste` entry ≤ 150 ms p50 / ≤ 250 ms p95
  over ≥ 20 warm utterances (signposts around toggle handler → paste).
- AC-D2 (R41): volatile partials visible in HUD during speech; committed text
  monotonic; finals-only accumulation verified against a scripted clip.
- AC-D3 (R36a): dictation started during a running ≥ 240 s file job completes
  within AC-D1 budgets (two-analyzer contention check; priority knob if needed).
- AC-D4 (np-G1): TCC ordering implemented; denying speech auth yields visible
  error, app never hangs.
- AC-D5: 20 cancel cycles mid-dictation leave no orphaned tasks/analyzers.
- AC-D6: session WAV + meta land in the sessions folder ≤ 2 s after paste.

### b-files-cli — file pipeline + CLI
- AC-F1 (R38): in-app file RTF ≤ 0.05× on ≥ 60 s audio.
- AC-F2 (np-G7): 16k mono i16 WAV transcribes byte-path (no conversion);
  m4a/AAC 48k transcribes; unsupported container → visible error, no crash.
- AC-F3: `.md` sidecar naming identical to 0.6.0; sessions meta correct.
- AC-F4: CLI implements §9 table exactly (subcommands, `--json` schema, exit
  codes); binary present at `Contents/MacOS/transcribe`; zipped app dropped on
  a clean macOS 26 account transcribes a file with zero installs (R44 story).
- AC-F5: Finder Quick Action still lands files into the app queue.

### b-locales — settings/locales/sessions
- AC-L1: startup capability probe ≤ 200 ms cached; menu reflects readiness.
- AC-L2 (np-G10): needsInstall locale → progress UI → ready; stall watchdog
  fires at 120 s with actionable error; cancel works.
- AC-L3 (ar-§5.4): 4 primaries reserved; overflow path releases LRU without
  user-visible failure.
- AC-L4: `locale` setting persists; picker = shipped set + Auto (R42/R42a).
- AC-L5: sessions layout byte-parity with §7 (day dirs, id format, meta keys);
  TTL sweep removes 1 h-live / 168 h-file artifacts; `clean --dry-run` parity.

### b-skill-docs — skill + positioning docs
- AC-S1: SKILL.md rewritten to §9 contract; smoke-tested from an agent shell
  (synthetic wav → parsed `--json` output).
- AC-S2 (R45c): docs/APPLE-SPEECH-API-NOTES.md published — sanitized api-recon
  (formats, finalize semantics, concurrency facts, locale assets, error table).
- AC-S3 (R45a/e): README headline + literal keywords staged; honesty rule held
  on main until release (MLX description stays until 0.7.0 ships).
- AC-S4 (R43/R45d): CHANGELOG Leggerissimo header + claim adjacency prepared;
  measured numbers filled at gates.

## 14. Existing behaviors that must NOT regress (all builders)

From the R36 lock, verified at merge gates:
1. Hotkey double-tap toggle semantics (tap starts, tap stops; no press-and-hold)
   and configurable `hotkey` from config.json.
2. HUD state machine: recording waveform / transcribing spinner (with file
   name) / flash kinds success·fileSuccess·empty·failure / cancelled upward
   glide / hidden — plus compact-pill + circle cluster when both lanes run.
3. Sounds: Pop (start), Tink (stop), Blow (cancel). Escape-to-cancel monitors.
4. Sessions folder opens from the menu; layout/TTL parity (§7).
5. Check for Updates flow (GitHub releases zip swap); About/version identity;
   menu-bar-only app (LSUIElement).
6. Sequential file queue (one active job, pending statuses) and file-job cancel.
7. Privacy posture: on-device only; no network egress except Update checks.
8. Clipboard behavior: paste + 1 h clearIfUnchanged TTL; copyOnly fallback when
   Accessibility missing (current app is the parity bar — owner words).

## 15. Open items (owner-eyes / coordinator)
- R44a Gatekeeper-vs-notarization pick before wide distribution (non-blocking).
- L-ASSET device state: it/es assets undelivered on the reference machine —
  System Settings workaround + OS-point-update retest; design degrades
  gracefully either way (§5.3).
- Default-locale heuristic ("auto" = system language) is our proposal per
  R42a; owner may prefer always-explicit.
- wer-kit BLOCKER-FOR-VERDICT stands with the coordinator/owner: ≥30 real
  utterances must be dictated + harvested inside the 1 h TTL window before any
  R39 GO/NO-GO.
