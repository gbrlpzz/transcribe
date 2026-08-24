# Changelog

## 1.2.7 — Glass, and a cast that finally renders

- The cast shadow is drawn literally now: a convex-hull silhouette layer
  whose own shadow does the casting — soft and diffuse per Apple's shadow
  language (radius 9, 32 %, zero offset: light straight through the
  screen). The previous root-layer shadow never rendered for sublayer-only
  content — measured zero pixels in a layer-tree probe.
- Glassier body: faces are translucent white (58 %) with a specular bevel
  stroke nudged toward the key light; the icon's gray edge recipe stays.

## 1.2.6 — The shadow actually ships

- Fixed: AppKit's default bounds clipping amputated the projection shadow
  before it reached the screen — you were never seeing it. Layer-backed
  views now opt out of default clipping and the silhouette halo renders.
- Shadow strengthened (45 % opacity, radius 10) and the body made
  near-opaque (96 %) so dense textured backgrounds can't eat the form.

## 1.2.5 — Projection shadow

- The solid now casts a soft silhouette shadow straight onto what's behind
  it (orthogonal light, zero offset): form reads against any window in any
  appearance. Five lines on the root layer — no new layers, no assets.

## 1.2.4 — Unfreeze + softer edge

- Fixed: after one finished dictation the solid froze at the done pose and
  never spun again — the settled flag wasn't cleared when a new run started.
- The edge hairline now uses the app icon's own stroke recipe (soft gray,
  hairline width) instead of a heavy near-black outline: still legible on
  light backgrounds without reading as drawn-on.

## 1.2.3 — Done lands as the icon

- The settle no longer stops at an arbitrary angle: the solid now arcs to
  the app-icon pose — vertex pointing at you inside an upright triangle —
  so completion is unmistakable from any spin state.
- Light-mode contrast: edge hairline darkened and doubled in weight
  (0.4 pt → 0.8 pt), contact shadow deepened. Same geometry, same motion,
  same line count.

## 1.2.2 — Launch at login

- Transcribe now starts on every login. The first launch registers it via
  SMAppService (macOS asks once under Login Items); later launches are
  silent no-ops, and opting out in Settings stays respected.

## 1.2.1 — Settle fix

- The done-pose settle is a fixed 0.8 s easeOutCubic that always completes
  (the 1.2.0 exponential decay crawled and read as never settling).
- The success flash holds 2.6 s — full settle plus a still moment, instead
  of dismissing the solid mid-settle at 1.6 s.

## 1.2.0 — One solid, nothing extra

- One tetrahedron, three behaviors: recording spins gently about one axis,
  transcribing tumbles reversed and faster about another, done eases into the
  canonical diamond rest pose and is still.
- HUD doubled in size; multiple HUDs distribute symmetrically around the
  notch center.
- Menu trimmed to Language / About / Quit: the hotkey is the dictate path,
  the Finder Quick Action is the file path, updates are automatic.
- **Sessions removed.** A dictation lives in the clipboard; a file transcript
  lives in the `.md` beside the audio. No WAV archive, no metadata, no TTL
  sweeper — the app forgets everything else.
- **CLI reduced to one command**: `transcribe <audio> [--json] [--locale ll-CC]`
  (`doctor` and `languages` verbs removed — the Language menu handles
  languages).
- **Lean full-auto updater**: checks GitHub at launch, downloads and swaps
  silently.
- App icon: corner-on tetrahedron, white on white, dead center.
- Install-event machinery, lane-id tracking, and retention config deleted.
- Battery: 32 cases + live smoke.

## 1.1.0 — Solid HUD

- The capsule pill is gone. The HUD is now a white translucent solid floating
  below the notch. Hairline edges, faint bloom, diffused contact shadow.
  Click still cancels, Esc still works, all flash timings unchanged.
- Empty/failure flashes removed: the HUD stands down silently and the existing
  alert path carries failure news. Success is the only flash.
- Language menu lists every locale macOS's speech stack offers (nothing
  hard-coded); startup warms only the system language.
- HUD + solid code: 810 → 418 lines; engine input-meter plumbing deleted;
  vector-only rendering — no assets, no new frameworks.
- Dead LocaleManager surface removed (`markActive`/`markInactive`,
  `releaseReservation`, `cancelInstall`, `readyLocales`, `currentReservations`)
  — zero production callers.
- Repo: legacy Python build/test artifacts and three unreferenced root icons
  removed; `.gitignore` reduced to native-only rules; release zip now zlib
  level 9.
- Battery: 47 cases + live smoke (was 50); `make test` added.

## 1.0.0 — Leggerissimo

Native rebuild on Apple's on-device speech stack (macOS 26 `SpeechAnalyzer`). The Python
engine, HTTP server, uv toolchain, model downloads, and ffmpeg dependency are gone.

Measured on the reference M4 (warm, p50 unless noted):

- dictation stop→paste-ready 58 ms (en), 42 ms (de); auto dual-language 68 ms; p95 122 ms
- file RTF 0.0175x cold / 0.0168x warm on a 240,000 ms recording; AAC identical within noise
- app bundle 621,567 B (binary 601,904 B signed, icon 15,613 B); release zip 256,394 B
- installed footprint: from ~1.5 GB (Python toolchain + models) to 621,567 B
- 50-case test battery green; live dual-lane, cancel-storm ×20, double-tap regression verified

Added:
- streaming recognition during speech (internal; paste latency is the visible effect)
- auto language mode: two recognizers on one stream, best committed lane wins (+4 ms)
- Language submenu (Auto/en/it/de/es variants) persisting to config.json
- universal `transcribe` CLI inside the app binary (file · doctor · languages), single-binary
  dispatch via argv[0]; agent-agnostic SKILL.md
- docs/APPLE-SPEECH-API-NOTES.md: verified field notes on the new Apple speech API

Changed:
- sessions and `<file>.md` outputs are byte-identical to 0.6.0 (sha256-verified)
- config.json gains `locale`; obsolete keys are ignored and no longer written
- minimum macOS is now 26

Removed:
- Python package, pytest suite, pyproject/uv packaging, engine server, port key
- model downloads and HF cache (~538,968,064 B), ffmpeg requirement, engine skill plumbing

## 0.6.0 — diet engine + honesty pass (unreleased)

Measured vs 0.5.0 on Apple M4, macOS 26.2 (August 2026). Every number below
is from an actual run. Dictation E2E was re-measured on the merged engine
under ~2x background system load: treat those rows as "unchanged within
noise" rather than regressions — the wins that are robust to load are listed
with their own isolated measurements.

| Area | 0.5.0 | 0.6.0 | Delta |
|---|---|---|---|
| Tool install size | 1,095,191,040 B | ~260,046,848 B fresh venv (`du -sk`) | −76% |
| Engine cold import (`import mlx_whisper`) | ~620–730 ms | ~122–142 ms steady | −~500 ms |
| Dictation fixed paste delay | +120 ms every utterance | kept after live testing showed synthetic Cmd+V races some apps' input handling | reliability first |
| ffmpeg decodes per dictation utterance | 2 (~31 ms each) | 0 (PCM read in-process) | −~31–62 ms per utterance |
| Short-utterance E2E (HTTP) | 1,020 ms median | 1,070 ms under 2x higher background load; unchanged within noise, minus the deleted paste delay and ffmpeg decodes | engine-side flat, app-side faster |
| Language detection cost | ~59–61 ms (ffmpeg spawn + decode) | **19–22 ms** (in-process PCM) | ~3x |
| Cold start to ready | 740 ms | **430 ms** | −42% |
| Stop → warm restart | 410 ms | **320 ms** | −22% |
| Engine idle memory | 1.0 GB footprint (vmmap) | **0.91 GB** footprint / 87 MB RSS | better |
| Dictate during file jobs | blocked (`engine busy` until the job ends) | utterance served from a temporary second model lane; lane auto-evicts when idle | parallel again |
| Long-session stability | quality can drift after dozens of jobs in one process | engine quietly rebuilds its warm model every 40 transcriptions (~0.5 s, invisible) | bounded |
| Engine memory idle-warm | ~1.0 GB physical footprint | ~1.0 GB (unchanged; weights dominate) | honest wording replaces "<0.9 GB" claim |
| Language detection honesty | claimed ~25 ms | measured 58.8–61.1 ms, docs corrected | truth |
| Release zip junk | 14 `__MACOSX/` entries | 0 entries (23 → 9 zip entries) | clean |
| Repo weight | +208 KB committed icon artifacts | deleted (regenerable via one script) | hygiene |
| App code | DictationPill 875 → 797 LOC (state table); 358 Swift lines deleted / 276 added app-wide (measured vs 0.5.0) | simpler |

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
