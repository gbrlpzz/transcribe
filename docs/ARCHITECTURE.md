# Architecture

Transcribe has four local parts:

1. The native Zig `transcribe` daemon.
2. The Python engine server.
3. The public `transcribe` command, which delegates file and engine commands.
4. The optional Prime Agent skill.

All communication stays on the Mac. HTTP uses `127.0.0.1:8765`; live dictation
uses the Unix socket at `~/Library/Application Support/transcribe/dictation.sock`.

```text
⌃␣
 │
 ▼
Zig transcribe daemon ── PCM over UDS ──▶ Python stream server
 │  Core Audio · VAD-free capture          │  VAD · chunked decode
 │  native paste                            │  warm MLX Whisper model
 │                                          │
 └─────────────── Finder / CLI ────────────▶ HTTP file transcription
```

## Core components

| Component | Location | Responsibility |
|---|---|---|
| Capture daemon | `daemon/src/` | Owns the global hotkey, Core Audio capture, Unix transport, and native paste. |
| Audio ring | `daemon/src/audio.zig` | Commits s16le/16 kHz mono frames from the realtime callback into a lock-free ring. |
| Engine client | `daemon/src/engine.zig` | Sends framed control/PCM messages and reads partial/final events. |
| Stream server | `transcribe/streamserver.py` | Gates silence, decodes chunks, deduplicates seams, and preserves raw nanosecond timings. |
| Engine | `transcribe/engine.py` | Keeps the tested `turbo-q4` model warm and selects MLX or the fallback backend. |
| HTTP server | `transcribe/server.py` | Exposes `/health`, `/transcribe`, and `/reload` for file jobs. It shares the warm model with streaming. |
| CLI | `transcribe/cli.py` | Implements file, engine, cleanup, configuration, model, and diagnostic commands behind the public front command. |
| Storage | `transcribe/storage.py` | Stores sessions and removes expired data. |

## Inference and concurrency

The engine keeps one model warm. MLX GPU streams are thread-local, so warm-up
and inference run on one dedicated engine thread. Streaming and HTTP requests
share that model without loading a second copy.

The daemon prepares Core Audio once at LaunchAgent startup. Each press only
activates the prepared stream and sends frames. Idle frames are discarded.
The hotkey callback wakes the worker through a semaphore; it does not poll at a
fixed 20 ms interval.

## Data flow

1. The user presses `⌃␣` (or the automatic `⌃⌥␣` fallback).
2. The daemon activates the prepared AUHAL input unit.
3. PCM frames go over the Unix socket to the stream server.
4. Energy VAD gates silence. Speech is decoded in chunks while the user speaks.
5. The daemon receives partial and final text.
6. Final text is pasted through macOS Accessibility using a native CGEvent.
7. Finder file requests use the HTTP endpoint and write `<file>.md` beside the source.

## Timing contract

The stream protocol includes both `elapsed_ms` for compatibility and raw
`elapsed_ns` for measurement. User-facing output formats the raw value in
nanoseconds, microseconds, milliseconds, or seconds. A missing measurement is
shown as `unmeasured`, never as a fabricated zero.

## Configuration

The shared engine configuration lives at:

```text
~/Library/Application Support/transcribe/config.json
```

The daemon keeps language automatic, uses its fixed shortcut, and uses the
matching Unix socket. Those daemon choices are not configuration settings.
