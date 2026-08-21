# Model and backend

Transcribe ships tested model profiles. The release default is `turbo-q4`.

The goal is simple behavior and predictable memory use. The app keeps one model warm. It does not load a second large model for file jobs or live dictation. A tiny helper model (whisper-tiny, about 80 MB) handles language detection only.

## Profiles

| Alias | Apple Silicon backend | Other supported backend | Languages | Role |
|---|---|---|---|---|
| `turbo-q4` | `mlx-community/whisper-large-v3-turbo-4bit` | `Systran/faster-whisper-turbo` | Multilingual | Default: fastest, smallest |
| `turbo-q8` | `mlx-community/whisper-large-v3-turbo-8bit` | `Systran/faster-whisper-turbo` | Multilingual | 8-bit alternative |
| `turbo` | `mlx-community/whisper-turbo` | `Systran/faster-whisper-turbo` | Multilingual | Full precision (fp16) |

On the `faster` backend all profiles resolve to the same CTranslate2 model; that backend applies its own compute-type optimization.

## Measured performance (M4, 16 GB, best of 3)

| Job | 0.3.x (fp16, auto language) | 0.4.x (turbo-q4, tiny detection) |
|---|---|---|
| Short dictation, about 6 s | about 1.9–2.0 s | about 1.1 s |
| Code-switched Italian/English, 10 s | about 2.1 s | about 1.1 s |
| Long English, 48 s | 3.5 s | 2.4 s |
| Long Italian, 48 s | 3.9 s | 2.6 s |

Accuracy stayed identical in benchmarks: 0% word error rate on the English sample and 0.8% on the Italian sample for both fp16 and 4-bit weights. The engine process stays at about 0.77–0.84 GB resident memory, down from about 2.1 GB.

## Memory behavior

- The 4-bit weights use about 450 MB of GPU memory.
- MLX reusable buffers are capped at 256 MB. Short dictation jobs stay under the cap and pay no penalty; long jobs evict as needed.
- A 30-second padded encoder pass is the fixed floor for Whisper on short clips. This is why dictation latency is about 1 second rather than proportional to clip length.

## Language detection

With `language: auto` (the default), the engine detects the spoken language on every utterance with whisper-tiny. This costs about 25 ms and keeps mixed Italian/English dictation working without per-utterance configuration. If the tiny detector reports low confidence, the engine falls back to the main model's own detection pass.

Set a fixed language to skip detection entirely:

```bash
transcribe config set language en
```

## Backends

| Backend | Use |
|---|---|
| `mlx` | Default on Apple Silicon. It uses the Apple GPU through MLX. |
| `faster` | Fallback for Intel Macs and other systems where MLX is unavailable. |

## Download and cache

Models are downloaded on first use:

```text
~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-4bit/
~/.cache/huggingface/hub/models--mlx-community--whisper-tiny/
```

Quantized repositories ship `model.safetensors`, while mlx-whisper loads `weights.safetensors`. The engine bridges this once with a directory of symlinks under the Transcribe data home (`models/` inside the data directory). The symlink directory holds no weight data itself.

Inspect the current model and backend:

```bash
transcribe doctor
transcribe models
```

Remove an unused model cache only when its repository is no longer configured. Do not remove the active model cache while the engine is running.

## Selecting a profile

```bash
transcribe config set model turbo-q8   # or turbo-q4, turbo
```

The engine also accepts a raw model repository path for development and testing. Raw paths are not part of the supported daemon configuration.
