# transcribe — the Zig capture daemon

`transcribe` is a resident macOS daemon that owns everything latency-critical
about dictation: the global hotkey, microphone capture, streaming transport,
and pasting. It is written in Zig, has no runtime dependencies, and ships as a
single ~500 KB native binary.

Design rule: **zero configuration**. Language is always auto-detected per
utterance (whisper-tiny LID), the model is always `turbo-q4`, and the socket
path is fixed. The primary hotkey is control+space. If macOS reserves it, the
daemon automatically uses control+option+space. The user never configures
anything — they press the hotkey and text appears.

## Architecture

```
┌────────────────────────┐        ┌──────────────────────────┐
│  transcribe (Zig)     │  UDS   │  transcribe streamserver │
│  · Carbon hotkey       │ ─────► │  (Python, warm engine)   │
│  · Core Audio capture  │ PCM    │  · energy VAD gate       │
│    s16le 16 kHz mono   │ ◄───── │  · chunked decode        │
│  · CGEvent paste       │ partial│  · seam dedupe           │
└────────────────────────┘  +final└──────────────────────────┘
```

- **Capture**: an AUHAL input unit with an s16le/16 kHz client format. The
  unit is prepared once when the daemon starts and only its live stream is
  activated per press. AUHAL performs rate conversion and packing internally;
  the render callback commits bytes straight into a lock-free ring (zero
  copies on the realtime thread). Idle frames are discarded.
- **Transport**: length-prefixed framing over an `AF_UNIX` stream — every
  message is a little-endian u32 length followed by payload. Payloads starting with `{`
  are JSON control messages; anything else is raw PCM.
- **Engine side** (`transcribe/streamserver.py`): an energy VAD trims silence,
  speech is decoded in chunks (≥1.5 s of speech plus a ≥320 ms pause, or a 4 s
  hard cap) so text starts appearing while you are still talking, and repeated
  words at chunk seams are deduped.

## Protocol v1

Client → server:

```json
{"op": "start", "language": "auto", "session": "<id>"}
```
then raw PCM frames (~100 ms each), then:
```json
{"op": "stop"}
```

Server → client events: `ready`, `partial {text}`, `final {text, elapsed_ms, elapsed_ns}`,
`error {msg}`.

The socket lives at `~/Library/Application Support/transcribe/dictation.sock`
(`TRANSCRIBE_DICTATION_SOCK` overrides; `TRANSCRIBE_HOME` moves the default).

## Building

```bash
cd daemon
zig build -Doptimize=ReleaseFast          # binary at zig-out/bin/transcribe
zig build test                            # unit tests
```

## Running

```bash
transcribe serve                          # warm engine (existing command)
transcribe run                           # daemon: hotkey becomes live
transcribe ping                          # check the engine socket
transcribe once --ms 3000 --no-paste     # one timed mic session (dev)
transcribe pipe clip.wav --no-paste      # replay a wav through the pipeline
```

First run grants: Microphone (capture), Accessibility (paste), and Input
Monitoring if the CoreGraphics fallback is needed. The legacy menu-bar app is not
part of the dictation path; file transcription stays on the Finder
Quick Action right-click flow.

## Why these numbers

Measured on the reference machine (see `bench/results/streaming.json`):

| Stage | Legacy (v0.4) | Streaming (v0.5.1) |
|---|---|---|
| Daemon audio warm-up | not resident | ~1.998 s once at LaunchAgent start |
| Capture activation per press | ~219 ms (ffmpeg spawn) | ~31–38 ms (AUHAL stream start) |
| Text appears | after full decode | during speech (partials) |
| Tail after key-up | full-file decode (~1.1 s for 9 s clip) | last-chunk decode only |
| Paste | pbcopy + osascript (~97 ms) | CGEvent direct (~1 ms) |
| Binary footprint | Python CLI + ffmpeg per press | one resident ~500 KB binary |
