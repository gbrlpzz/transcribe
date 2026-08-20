# Model and backend

Transcribe ships one tested model profile: `turbo`.

The goal is simple behavior and predictable memory use. The app keeps one model warm. It does not load a second model for file jobs or live dictation.

## Default profile

| Alias | Apple Silicon backend | Other supported backend | Languages | Role |
|---|---|---|---|---|
| `turbo` | `mlx-community/whisper-turbo` | `Systran/faster-whisper-turbo` | Multilingual | Tested default |

The MLX weights are about 1.6 GB on disk. A clean-process benchmark on a 16 GB Apple Silicon Mac used about 2.6 GB physical memory while transcribing a 51-second file. Memory can rise for long files because audio features and decoder work are also kept during the request.

## Backends

| Backend | Use |
|---|---|
| `mlx` | Default on Apple Silicon. It uses the Apple GPU through MLX. |
| `faster` | Fallback for Intel Macs and other systems where MLX is unavailable. |

The engine selects MLX on Apple Silicon when `backend` is `auto`. Set `backend` to `faster` only when MLX is not available.

## Model behavior

The release profile accepts `turbo` as the supported model alias. The engine also accepts a raw model repository path for development and testing. Raw paths are not part of the supported menu-bar configuration.

One model stays loaded between requests. This avoids repeated downloads and avoids keeping multiple large models in unified memory. File and live jobs use the same engine thread. Their HUD states remain independent, but model work is serialized for memory and MLX GPU-stream safety.

## Download and cache

The model is downloaded on first use and stored under:

```text
~/.cache/huggingface/hub/models--mlx-community--whisper-turbo/
```

Inspect the current model and backend:

```bash
transcribe doctor
transcribe models
```

Remove an unused model cache only when its repository is no longer configured. Do not remove the active `whisper-turbo` cache while the engine is running.

## Selecting a language

The default language is `auto`. You can set a fixed language:

```bash
transcribe config set language en
```

The `turbo` profile supports multilingual speech. A fixed language can improve results when the language is known.
