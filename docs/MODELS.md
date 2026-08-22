# Model

Transcribe ships one model and makes no model choices available: 4-bit Whisper turbo (`turbo-q4`, `mlx-community/whisper-large-v3-turbo-4bit`), always warm, on MLX.

The goal is simple behavior and predictable memory use. The app keeps one model warm. It does not load a second large model for file jobs or live dictation. A tiny helper model (whisper-tiny, 71 MB on disk, roughly 150 MB of additional runtime footprint) handles language detection only.

## Measured baselines (installed 0.5.0 engine, M4, 16 GB, macOS 26.2, August 2026)

Short-utterance dictation over HTTP: about 1.02 s for a 2 s clip and 1.09 s for 10 s (median of 3). A 30 s clip takes about 9.0 s (roughly 0.30x realtime). A 4-minute WAV file transcribes in about 70 s (0.29x realtime). Language detection adds about 60 ms per utterance (see below).

<!-- TODO(gates): refresh these medians on the 0.6.0 engine after merge; coordinator owns the re-bench -->

## Historical accuracy comparison (best of 3)

| Job | fp16 with auto language | turbo-q4 with tiny detection |
|---|---|---|
| Short dictation, about 6 s | about 1.9–2.0 s | about 1.1 s |
| Code-switched Italian/English, 10 s | about 2.1 s | about 1.1 s |
| Long English, 48 s | 3.5 s | 2.4 s |

Accuracy stayed identical in benchmarks: 0% word error rate on the English sample and 0.8% on the Italian sample for both fp16 and 4-bit weights.

## Memory behavior

- The 4-bit weights use about 450 MB.
- MLX reusable buffers are capped at 256 MB. Short dictation jobs stay under the cap and pay no penalty; long jobs evict as needed.
- A 30-second padded encoder pass is the fixed floor for Whisper on short clips. This is why dictation latency is about 1 second rather than proportional to clip length.
- Measured engine memory (`vmmap --summary` physical footprint, Apple M4, macOS 26.2, August 2026): about 1.0 GB idle-warm and up to about 1.7 GB during transcription. `ps` RSS reports only 0.17–0.21 GB because MLX weights live in unified GPU memory that RSS undercounts.

## Language detection

Language is always detected automatically per utterance with whisper-tiny. This costs about 60 ms per utterance (58.8–61.1 ms median across 2/10/30 s clips, 20 runs each, including audio decode; measured via the engine's own detector path) and keeps mixed Italian/English dictation working without configuration. If the tiny detector reports low confidence, the engine falls back to the main model's own detection pass.

## Download and cache

Models are downloaded on first use:

```text
~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-4bit/
~/.cache/huggingface/hub/models--mlx-community--whisper-tiny/
```

Together they take roughly 520 MB on disk: about 450 MB for turbo-q4 and about 71 MB for whisper-tiny.

Quantized repositories ship `model.safetensors`, while mlx-whisper loads `weights.safetensors`. The engine bridges this once with a directory of symlinks under the Transcribe data home (`models/` inside the data directory). The symlink directory holds no weight data itself.

Inspect the setup:

```bash
transcribe doctor
```

Do not remove the active model cache while the engine is running.
