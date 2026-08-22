import shutil
import wave

import numpy as np
import pytest

from transcribe.engine import DEFAULT_MODEL_REPO, LID_MODEL


def test_release_ships_exactly_one_model():
    assert DEFAULT_MODEL_REPO == "mlx-community/whisper-large-v3-turbo-4bit"


def test_language_detection_uses_whisper_tiny():
    assert LID_MODEL == "mlx-community/whisper-tiny"


def _write_pcm_wav(path: str, samples: np.ndarray) -> None:
    with wave.open(path, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(16000)
        fh.writeframes(samples.tobytes())


class _FakeLid:
    """Minimal whisper-tiny stand-in so no real weights are needed."""

    def __init__(self):
        import types
        self.dims = types.SimpleNamespace(n_mels=80)

    def detect_language(self, segment):
        import mlx.core as mx
        return None, {"en": mx.array(0.99)}


class _FakeMlx:
    """Records how the engine hands audio to mlx_whisper.transcribe."""

    def __init__(self):
        self.received = None
        self.language = None

    def transcribe(self, audio, path_or_hf_repo=None, language=None):
        self.received = audio
        self.language = language
        return {"text": "hello world", "language": language or "en"}


@pytest.fixture(name="stub_transcriber")
def _stub_transcriber(monkeypatch):
    from transcribe.engine import Transcriber

    t = Transcriber()
    t.load = lambda: None  # skip weight resolution; nothing is downloaded here
    t._lid = _FakeLid()
    t._main_model = object()
    t._mlx = _FakeMlx()

    # _restore_main_in_holder mutates mlx-whisper's process-global holder;
    # put whatever this process had back afterwards.
    from mlx_whisper.transcribe import ModelHolder
    saved = (ModelHolder.model, ModelHolder.model_path)
    yield t
    ModelHolder.model, ModelHolder.model_path = saved


def test_wav_transcription_decodes_once_without_subprocess(tmp_path, monkeypatch, stub_transcriber):
    """PCM WAV dictation path: zero subprocesses, one shared float32 array.

    Both language detection and mlx_whisper.transcribe must receive the same
    in-memory waveform; passing a path would spawn an ffmpeg decode per pass.
    """
    import subprocess

    def _no_spawn(*args, **kwargs):
        raise AssertionError("subprocess spawned during PCM WAV transcription")

    for name in ("run", "Popen", "check_output", "check_call", "call"):
        monkeypatch.setattr(subprocess, name, _no_spawn)

    # belt and braces: the backend's own file decoder must never be reached
    monkeypatch.setattr("mlx_whisper.audio.load_audio", _no_spawn)

    ints = (np.sin(np.linspace(0, 440 * 2 * np.pi, 16000)) * 8000).astype(np.int16)
    wav = tmp_path / "utterance.wav"
    _write_pcm_wav(str(wav), ints)

    result = stub_transcriber.transcribe(str(wav))

    assert result["text"] == "hello world"
    received = stub_transcriber._mlx.received
    assert received.dtype == np.float32 and received.ndim == 1
    assert received.shape == (16000,)
    np.testing.assert_allclose(
        received, ints.astype(np.float32) / np.float32(32768.0))


@pytest.mark.skipif(shutil.which("ffmpeg") is None,
                    reason="non-PCM containers normalize through ffmpeg")
def test_non_wav_input_keeps_ffmpeg_normalization(tmp_path, monkeypatch, stub_transcriber):
    """Non-PCM containers still normalize via audio_to_wav before decoding."""
    calls = []
    real_audio_to_wav = __import__("transcribe.audio", fromlist=["audio_to_wav"]).audio_to_wav

    def fake_normalize(path):
        calls.append(path)
        out = tmp_path / "normalized.wav"
        _write_pcm_wav(str(out), np.zeros(1600, dtype=np.int16))
        return str(out)

    monkeypatch.setattr("transcribe.engine.audio_to_wav", fake_normalize)

    bogus = tmp_path / "clip.m4a"
    bogus.write_bytes(b"not really aac")
    result = stub_transcriber.transcribe(str(bogus))

    assert calls == [str(bogus)]
    assert result["text"] == "hello world"
    # the temporary normalized wav is cleaned up by the engine
    assert not (tmp_path / "normalized.wav").exists()


def test_release_version():
    import transcribe

    assert transcribe.__version__ == "0.6.0"
