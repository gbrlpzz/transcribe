# Models and Backends

Transcribe supports OpenAI Whisper models optimized for Apple Silicon (MLX) and standard CPU/CUDA environments (faster-whisper).

---

## Inference Backends

| Backend | Engine | Platform | Notes |
|---|---|---|---|
| `mlx` *(default)* | [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) | Apple Silicon (M1/M2/M3/M4) | Runs Whisper at 8–15× real-time using unified GPU memory. |
| `faster` | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) | Intel macOS & Linux | CTranslate2 backend; recommended fallback for non-Apple hardware. |

To switch backends manually:
```bash
transcribe config set backend faster
```

---

## Supported Models

| Alias | MLX Repository | faster-whisper Repository | Size | Languages | Typical Speed |
|---|---|---|---|---|---|
| `large-v3-turbo` *(default)* | `mlx-community/whisper-large-v3-turbo` | `Systran/faster-whisper-large-v3-turbo` | ~1.6 GB | Multilingual | ~8× real-time |
| `large-v3` | `mlx-community/whisper-large-v3` | `Systran/faster-whisper-large-v3` | ~3.0 GB | Multilingual | ~3× real-time |
| `medium` | `mlx-community/whisper-medium` | `Systran/faster-whisper-medium` | ~1.5 GB | Multilingual | ~10× real-time |
| `small` | `mlx-community/whisper-small` | `Systran/faster-whisper-small` | ~470 MB | Multilingual | ~15× real-time |
| `turbo` | `mlx-community/whisper-turbo` | `Systran/faster-whisper-turbo` | ~800 MB | English only | ~12× real-time |

---

## Managing Models

### Changing the Active Model
Switch models using the CLI:
```bash
transcribe config set model large-v3
```
Or select a model directly from the **Model** submenu in the macOS menu bar. The running engine server automatically hot-reloads the new model weights into memory.

### Language Selection
By default, language detection is set to `auto`. Whisper detects spoken language dynamically on each utterance (English, Italian, Spanish, French, German, and 90+ others).

To pin a specific language for faster, fixed transcription:
```bash
transcribe config set language it    # Italian
transcribe config set language en    # English
transcribe config set language auto  # Auto-detect (default)
```
