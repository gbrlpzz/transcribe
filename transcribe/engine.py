"""Transcription engine.

One backend (MLX on Apple Silicon), one model (4-bit Whisper turbo), one
language mode (automatic per-utterance detection). Models are downloaded once
from Hugging Face and cached locally; transcription never leaves the machine.
"""

from __future__ import annotations

import os
import time
from typing import Any

from transcribe.audio import audio_to_wav, is_pcm_wav

# models are cached locally; hide the "Fetching 4 files" hub flash on repeat runs
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

# The release model: identical accuracy to fp16 in benchmarks, ~12% faster
# decode, about a third of the weight memory (452 MB vs 1543 MB GPU-resident).
DEFAULT_MODEL_REPO = "mlx-community/whisper-large-v3-turbo-4bit"

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
        try:
            # Cached models resolve locally without a hub round-trip, which
            # shaves latency off every engine start.
            snapshot = Path(snapshot_download(repo_id=repo, local_files_only=True))
        except Exception:
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


class Transcriber:
    """Lazy-loaded, warm transcriber shared by the CLI and the local server."""

    def __init__(self):
        self.model = DEFAULT_MODEL_REPO
        self._mlx = None
        self._lid = None            # whisper-tiny language detector (lazy)
        self._main_model = None     # direct reference to the resident model
        self._model_path: str | None = None  # local path mlx-whisper loads
        self._cache_limited = False

    def _limit_gpu_cache(self) -> None:
        """Bound MLX's reusable GPU buffer cache once per process."""
        if self._cache_limited:
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
        if self._mlx is None:
            import mlx_whisper
            self._mlx = mlx_whisper
            self._model_path = _local_model_path(self.model)

    def warm(self) -> None:
        """Load backend code and model weights before the first request."""
        self.load()
        # mlx-whisper keeps its model in a process-global holder. Calling
        # only ``import mlx_whisper`` left the expensive snapshot download
        # and weight load on first dictation.
        self._load_main()
        self._load_lid()  # first dictation should not pay tiny's load

    @property
    def is_warm(self) -> bool:
        return self._main_model is not None

    def transcribe(self, audio_path: str) -> dict[str, Any]:
        self.load()
        t0 = time.time()

        # The native recorder already produces 16 kHz mono PCM WAV. Let the
        # backend decode that file directly; normalizing it first would invoke
        # ffmpeg twice. Keep normalization for arbitrary external formats and
        # malformed/non-PCM WAV files so their errors remain actionable.
        temporary_wav = not is_pcm_wav(audio_path)
        wav_path = audio_to_wav(audio_path) if temporary_wav else audio_path
        try:
            # Fast per-utterance detection keeps mixed-language dictation
            # working without the main model's ~0.9 s auto-detect pass.
            # Low confidence falls back to it.
            lang = None
            lid_lang, confidence = self._detect_language(wav_path)
            if lid_lang and confidence >= LID_CONFIDENCE_THRESHOLD:
                lang = lid_lang
            self._load_main()
            self._restore_main_in_holder()
            result = self._mlx.transcribe(
                wav_path,
                path_or_hf_repo=self._model_path or self.model,
                language=lang,
            )
            text = result.get("text", "").strip()
            detected = result.get("language", lang or "")
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
            "elapsed": round(elapsed, 2),
        }


def transcribe(audio_path: str) -> dict[str, Any]:
    """One-shot transcription (loads the model, transcribes, returns)."""
    return Transcriber().transcribe(audio_path)
