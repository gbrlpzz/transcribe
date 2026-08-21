"""Transcription engines.

Two local backends, auto-selected:

- ``mlx``  — mlx-whisper. The default on Apple Silicon: Whisper turbo stays
  warm for reliable local dictation and file transcription.
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

# Tested model profiles. The 4-bit profile is the release default: identical
# accuracy to fp16 in benchmarks, ~12% faster decode, and about a third of the
# weight memory (452 MB vs 1543 MB GPU-resident on an M4). The raw repository
# path remains accepted for development.
MODELS: dict[str, dict[str, str]] = {
    "turbo-q4": {
        "mlx": "mlx-community/whisper-large-v3-turbo-4bit",
        "faster": "Systran/faster-whisper-turbo",
        "languages": "multilingual — fast 4-bit default",
    },
    "turbo-q8": {
        "mlx": "mlx-community/whisper-large-v3-turbo-8bit",
        "faster": "Systran/faster-whisper-turbo",
        "languages": "multilingual — 8-bit alternative",
    },
    "turbo": {
        "mlx": "mlx-community/whisper-turbo",
        "faster": "Systran/faster-whisper-turbo",
        "languages": "multilingual — full precision (fp16)",
    },
}

DEFAULT_MODEL = "turbo-q4"

# Fast per-utterance language detection. whisper-tiny's encoder is far smaller
# than turbo's, so using it for language ID instead of the main model's own
# auto-detect saves ~0.9 s per utterance while keeping per-request detection
# (mixed Italian/English dictation keeps working utterance by utterance).
LID_MODEL = "mlx-community/whisper-tiny"
LID_CONFIDENCE_THRESHOLD = 0.6

# MLX keeps a GPU buffer cache between runs. Left unbounded it grows past
# 1 GB on long jobs and stays resident. A 256 MiB cap keeps dictation latency
# unchanged (short jobs stay under the cap) and bounds worst-case footprint.
GPU_CACHE_LIMIT_BYTES = 256 * 1024 * 1024


def _local_model_path(repo: str) -> str:
    """Resolve a repository id to a local path mlx-whisper can load.

    Quantized mlx-community repositories ship ``model.safetensors``, while
    mlx-whisper loads ``weights.safetensors``. For such repos, build a small
    shim directory of symlinks under the Transcribe data home once and reuse
    it for every later load.
    """
    from pathlib import Path

    try:
        from huggingface_hub import snapshot_download
        snapshot = Path(snapshot_download(repo_id=repo))
    except Exception:
        return repo  # let mlx-whisper surface its own download error
    if ((snapshot / "weights.safetensors").exists()
            or (snapshot / "weights.npz").exists()):
        return str(snapshot)
    if not (snapshot / "model.safetensors").exists():
        return str(snapshot)

    from transcribe.config import default_home
    shim = Path(default_home()) / "models" / repo.replace("/", "--")
    shim.mkdir(parents=True, exist_ok=True)
    for item in snapshot.iterdir():
        if item.is_file():
            link = shim / item.name
            if not link.exists():
                link.symlink_to(item)
    weights = shim / "weights.safetensors"
    if not weights.exists():
        weights.symlink_to(snapshot / "model.safetensors")
    return str(shim)


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
        self._lid = None            # whisper-tiny language detector (lazy)
        self._main_model = None     # direct reference to the resident model
        self._model_path: str | None = None  # local path mlx-whisper loads
        self._cache_limited = False

    def _limit_gpu_cache(self) -> None:
        """Bound MLX's reusable GPU buffer cache once per process."""
        if self._cache_limited or self.backend != "mlx":
            return
        try:
            import mlx.core as mx
            mx.set_cache_limit(GPU_CACHE_LIMIT_BYTES)
        except Exception:
            pass  # older MLX without the API: keep default behavior
        self._cache_limited = True

    def _load_lid(self) -> None:
        """Load the whisper-tiny language detector once."""
        if self._lid is None:
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder
            ModelHolder.get_model(LID_MODEL, dtype=mx.float16)
            self._lid = ModelHolder.model

    def _detect_language(self, wav_path: str) -> tuple[str | None, float]:
        """Detect the spoken language with whisper-tiny (~25 ms per call).

        Returns ``(language, confidence)``; ``(None, 0.0)`` signals the caller
        should fall back to the main model's own detection.
        """
        try:
            import mlx.core as mx
            from mlx_whisper.audio import N_SAMPLES, log_mel_spectrogram, pad_or_trim
            self._load_lid()
            mel = log_mel_spectrogram(
                wav_path, n_mels=self._lid.dims.n_mels, padding=N_SAMPLES)
            segment = pad_or_trim(mel, 3000, axis=-2).astype(mx.float16)
            _, probs = self._lid.detect_language(segment)
            mx.eval(probs)
            lang = max(probs, key=probs.get)
            return lang, float(probs[lang])
        except Exception:
            return None, 0.0

    def _load_main(self) -> None:
        """Load the main model once and keep a direct reference to it."""
        if self._main_model is not None:
            return
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder
        ModelHolder.get_model(self._model_path or self.model, dtype=mx.float16)
        self._main_model = ModelHolder.model

    def _restore_main_in_holder(self) -> None:
        """Point mlx-whisper's process-global holder back at the main model.

        The holder keeps a single model. Loading whisper-tiny for language
        detection swaps it, and ``mlx_whisper.transcribe`` calls
        ``ModelHolder.get_model`` internally — it would reload the full
        weights from disk on every utterance if the holder still held tiny.
        Language detection and inference share one engine thread, so this
        pointer swap is race-free.
        """
        if self._main_model is None:
            return
        from mlx_whisper.transcribe import ModelHolder
        if ModelHolder.model is not self._main_model:
            ModelHolder.model = self._main_model
            ModelHolder.model_path = self._model_path or self.model

    def load(self) -> None:
        self._limit_gpu_cache()
        if self.backend == "mlx" and self._mlx is None:
            import mlx_whisper
            self._mlx = mlx_whisper
            self._model_path = _local_model_path(self.model)
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
            self._load_main()
            if self.language == "auto":
                self._load_lid()  # first dictation should not pay tiny's load

    @property
    def is_warm(self) -> bool:
        if self.backend == "mlx":
            return self._main_model is not None
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
                if lang is None:
                    # Fast per-utterance detection keeps mixed-language
                    # dictation working without the main model's ~0.9 s
                    # auto-detect pass. Low confidence falls back to it.
                    lid_lang, confidence = self._detect_language(wav_path)
                    if lid_lang and confidence >= LID_CONFIDENCE_THRESHOLD:
                        lang = lid_lang
                self._load_main()
                self._restore_main_in_holder()
                result = self._mlx.transcribe(
                    wav_path,
                    path_or_hf_repo=self._model_path or self.model,
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

    rec_model = "turbo"
    model_reason = "Tested default with one warm local model"

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
