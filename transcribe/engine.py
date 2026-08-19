"""Transcription engines.

Two local backends, auto-selected:

- ``mlx``  — mlx-whisper. The default on Apple Silicon: Whisper large-v3-turbo
  runs at several times real-time with near-large-v3 accuracy.
- ``faster`` — faster-whisper (CTranslate2). Fallback for Intel Macs, Linux,
  and any machine where MLX is not available.

Models are downloaded once from Hugging Face and cached locally; transcription
itself never leaves the machine.
"""

from __future__ import annotations

import os
import platform
import time
from typing import Any

from transcribe.audio import audio_to_wav, is_pcm_wav

# models are cached locally; hide the "Fetching 4 files" hub flash on repeat runs
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

# alias -> (mlx repo, faster-whisper repo, languages)
MODELS: dict[str, dict[str, str]] = {
    "turbo": {
        "mlx": "mlx-community/whisper-turbo",
        "faster": "Systran/faster-whisper-turbo",
        "languages": "default — fastest (~1.0s latency)",
    },
    "large-v3-turbo": {
        "mlx": "mlx-community/whisper-large-v3-turbo",
        "faster": "Systran/faster-whisper-large-v3-turbo",
        "languages": "multilingual (best accuracy/speed balance)",
    },
    "large-v3": {
        "mlx": "mlx-community/whisper-large-v3",
        "faster": "Systran/faster-whisper-large-v3",
        "languages": "multilingual (maximum accuracy, slower)",
    },
    "medium": {
        "mlx": "mlx-community/whisper-medium",
        "faster": "Systran/faster-whisper-medium",
        "languages": "multilingual",
    },
    "small": {
        "mlx": "mlx-community/whisper-small",
        "faster": "Systran/faster-whisper-small",
        "languages": "multilingual",
    },
}

DEFAULT_MODEL = "mlx-community/whisper-turbo"


def resolve_model(model: str, backend: str) -> str:
    """Map a short alias to the concrete repo for the chosen backend."""
    if model in MODELS:
        return MODELS[model][backend]
    return model


def available_backends() -> list[str]:
    out = []
    try:
        import mlx_whisper  # noqa: F401
        out.append("mlx")
    except ImportError:
        pass
    try:
        import faster_whisper  # noqa: F401
        out.append("faster")
    except ImportError:
        pass
    return out


def detect_backend(preference: str = "auto") -> str:
    """Pick a backend: preference, or mlx on Apple Silicon, else faster."""
    if preference in ("mlx", "faster"):
        return preference
    backends = available_backends()
    if "mlx" in backends and platform.machine() == "arm64":
        return "mlx"
    if "faster" in backends:
        return "faster"
    raise RuntimeError(
        "no transcription backend installed — run `uv pip install mlx-whisper` "
        "(Apple Silicon) or `uv pip install faster-whisper` (any Mac/Linux)"
    )


class Transcriber:
    """Lazy-loaded, cached transcriber shared by the CLI and the local server."""

    def __init__(self, model: str = DEFAULT_MODEL, backend: str = "auto",
                 language: str = "auto"):
        # Resolve the backend once. Besides avoiding duplicate import/probe
        # work, this guarantees model resolution and the selected backend stay
        # in lockstep when auto-detection is used.
        self.backend = detect_backend(backend)
        self.model = resolve_model(model, self.backend)
        self.language = language
        self._mlx = None
        self._faster = None

    def load(self) -> None:
        if self.backend == "mlx" and self._mlx is None:
            import mlx_whisper
            self._mlx = mlx_whisper
        elif self.backend == "faster" and self._faster is None:
            from faster_whisper import WhisperModel
            self._faster = WhisperModel(self.model, device="auto", compute_type="auto")

    def warm(self) -> None:
        """Load backend code and model weights before the first request."""
        self.load()
        if self.backend == "mlx":
            # mlx-whisper keeps its model in a process-global holder. Calling
            # only ``import mlx_whisper`` (the old warm-up behavior) left the
            # expensive snapshot download and weight load on first dictation.
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder
            ModelHolder.get_model(self.model, dtype=mx.float16)

    @property
    def is_warm(self) -> bool:
        if self.backend == "mlx":
            try:
                from mlx_whisper.transcribe import ModelHolder
                return ModelHolder.model is not None and ModelHolder.model_path == self.model
            except ImportError:
                return False
        return self._faster is not None

    def transcribe(self, audio_path: str, *, language: str | None = None,
                   verbose: bool = False) -> dict[str, Any]:
        self.load()
        requested = language or self.language   # per-call overrides instance
        lang = None if requested == "auto" else requested
        t0 = time.time()

        # The native recorder already produces 16 kHz mono PCM WAV. Let the
        # backend decode that file directly; normalizing it first would invoke
        # ffmpeg twice. Keep normalization for arbitrary external formats and
        # malformed/non-PCM WAV files so their errors remain actionable.
        temporary_wav = not is_pcm_wav(audio_path)
        wav_path = audio_to_wav(audio_path) if temporary_wav else audio_path
        try:
            if self.backend == "mlx":
                result = self._mlx.transcribe(
                    wav_path,
                    path_or_hf_repo=self.model,
                    language=lang,
                    verbose=None if not verbose else verbose,
                )
                text = result.get("text", "").strip()
                detected = result.get("language", lang or "")
            else:
                segments, info = self._faster.transcribe(
                    wav_path, language=lang, vad_filter=True
                )
                parts = [seg.text.strip() for seg in segments]
                text = " ".join(parts).strip()
                detected = info.language if lang is None else lang
        finally:
            if temporary_wav and wav_path and os.path.exists(wav_path):
                try:
                    os.remove(wav_path)
                except OSError:
                    pass
        elapsed = time.time() - t0
        return {
            "text": text,
            "language": detected or "",
            "model": self.model,
            "backend": self.backend,
            "elapsed": round(elapsed, 2),
        }


def transcribe(audio_path: str, *, model: str = DEFAULT_MODEL,
               backend: str = "auto", language: str = "auto",
               verbose: bool = False) -> dict[str, Any]:
    """One-shot transcription (loads the model, transcribes, returns)."""
    return Transcriber(model=model, backend=backend, language=language)        .transcribe(audio_path, verbose=verbose)


def detect_system_info() -> dict[str, Any]:
    """Inspect the local machine and return hardware specs and tailored recommendations."""
    import subprocess
    sys_name = platform.system()
    machine = platform.machine()
    is_apple_silicon = sys_name == "Darwin" and machine == "arm64"

    ram_gb = 0
    cpu_brand = ""
    if sys_name == "Darwin":
        try:
            mem_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip())
            ram_gb = round(mem_bytes / (1024 ** 3))
        except Exception:
            pass
        try:
            cpu_brand = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
        except Exception:
            pass
    elif sys_name == "Linux":
        try:
            mem_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
            ram_gb = round(mem_bytes / (1024 ** 3))
        except Exception:
            pass

    if is_apple_silicon:
        hw_desc = f"Apple Silicon ({cpu_brand or 'M-series'}, {ram_gb} GB Unified Memory)" if ram_gb else f"Apple Silicon ({cpu_brand or 'M-series'})"
        rec_backend = "mlx"
        rec_backend_pkg = "mlx-whisper"
        install_cmd = "uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe --with mlx-whisper"
    else:
        hw_desc = f"{sys_name} ({machine}, {ram_gb} GB RAM)" if ram_gb else f"{sys_name} ({machine})"
        rec_backend = "faster"
        rec_backend_pkg = "faster-whisper"
        install_cmd = "uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe --with faster-whisper"

    if ram_gb and ram_gb < 8:
        rec_model = "small"
        model_reason = f"Lightweight ({ram_gb} GB RAM available)"
    else:
        rec_model = "turbo"
        model_reason = "Default (fastest ~1.0s response, near-large-v3 accuracy)"

    return {
        "is_apple_silicon": is_apple_silicon,
        "hardware_desc": hw_desc,
        "ram_gb": ram_gb,
        "cpu_brand": cpu_brand,
        "recommended_backend": rec_backend,
        "recommended_backend_pkg": rec_backend_pkg,
        "install_cmd": install_cmd,
        "recommended_model": rec_model,
        "model_reason": model_reason,
    }
