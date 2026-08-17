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
---

## System Requirements & Resource Planning

Whisper runs entirely in-memory on your machine. On Apple Silicon, MLX shares Unified Memory between CPU and GPU cores with zero copy overhead.

### Hardware & RAM Recommendations

| Machine Configuration | Recommended Model | Expected Latency |
|---|---|---|
| **Apple Silicon (8 GB Unified Memory)** | `large-v3-turbo` or `medium` | ~1.0 – 1.8 s per utterance |
| **Apple Silicon (16 GB – 128 GB)** | `large-v3-turbo` or `large-v3` | ~0.8 – 1.5 s per utterance |
| **Intel Mac (8 GB RAM)** | `small` or `medium` (via `faster-whisper`) | ~2.5 – 4.0 s per utterance |
| **Intel Mac (16 GB+ RAM)** | `large-v3-turbo` (via `faster-whisper`) | ~2.0 – 3.5 s per utterance |

### Disk Storage

- Engine and Python environment: ~200 MB
- Hugging Face cache directory (`~/.cache/huggingface/hub/`):
  - `large-v3-turbo`: ~1.6 GB
  - `large-v3`: ~3.0 GB
  - `medium`: ~1.5 GB
  - `small`: ~470 MB
  - `turbo`: ~800 MB
- Ensure your primary disk has at least **3 GB free** before initial setup.
