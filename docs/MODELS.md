# Models

Transcribe uses OpenAI Whisper models converted for local inference.

## Backends

| Backend | Engine | When |
|---|---|---|
| `mlx` *(default on Apple Silicon)* | [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) | MLX runs Whisper at several times real-time on Apple Silicon with near-OpenAI accuracy |
| `faster` | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) | CTranslate2; fallback for Intel Macs and Linux |

`transcribe config set backend faster` to force the fallback.

## Model registry

| Alias | mlx repo | faster-whisper repo | Languages |
|---|---|---|---|
| `large-v3-turbo` | `mlx-community/whisper-large-v3-turbo` | `Systran/faster-whisper-large-v3-turbo` | multilingual |
| `large-v3` | `mlx-community/whisper-large-v3` | `Systran/faster-whisper-large-v3` | multilingual |
| `medium` | `mlx-community/whisper-medium` | `Systran/faster-whisper-medium` | multilingual |
| `small` | `mlx-community/whisper-small` | `Systran/faster-whisper-small` | multilingual |
| `turbo` | `mlx-community/whisper-turbo` | `Systran/faster-whisper-turbo` | English only |

Set with `transcribe config set model <alias>` or via the app's **Model** menu.
Changing the model while the engine server is running hot-reloads it
(`POST /reload`).

## Recommendations

- **Default: `large-v3-turbo`.** Whisper's turbo distillation keeps ~99% of
  large-v3 accuracy at ~8× the speed on MLX; it is multilingual (English and
  Italian both work well, with auto-detection).
- **Max accuracy:** `large-v3` when you don't mind slower round-trips.
- **English-only, fastest:** `turbo`.
- **Battery/disk-conscious:** `small` or `medium`.

## Language

`language` defaults to `auto` — Whisper detects the spoken language per
utterance (excellent for mixed English/Italian). Pin it with
`transcribe config set language en` for slightly faster, more stable results
when you always dictate in one language.
