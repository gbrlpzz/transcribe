import shutil
import subprocess

import pytest

from transcribe.audio import audio_to_wav, is_pcm_wav


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is required")
def test_audio_to_wav_decodes_common_audio_containers(tmp_path):
    source = tmp_path / "source.wav"
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
         "-ac", "2", "-ar", "48000", str(source)],
        check=True,
    )

    outputs = {
        "m4a": ["-c:a", "aac"],
        "mp3": ["-c:a", "libmp3lame"],
        "ogg": ["-c:a", "libvorbis"],
        "flac": ["-c:a", "flac"],
    }
    for extension, codec in outputs.items():
        media = tmp_path / f"sample.{extension}"
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-i", str(source), *codec, str(media)],
            check=True,
        )
        normalized = audio_to_wav(str(media))
        try:
            assert is_pcm_wav(normalized)
        finally:
            normalized_path = __import__("pathlib").Path(normalized)
            normalized_path.unlink(missing_ok=True)


def test_read_pcm_wav_dtype_shape_and_normalization(tmp_path):
    import wave

    import numpy as np

    from transcribe.audio import read_pcm_wav

    ints = np.array([0, 16384, -16384, 32767, -32768], dtype=np.int16)
    path = tmp_path / "clip.wav"
    with wave.open(str(path), "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(16000)
        fh.writeframes(ints.tobytes())

    samples = read_pcm_wav(str(path))
    assert samples.dtype == np.float32
    assert samples.ndim == 1
    assert samples.shape == (5,)
    # scaling matches the backend's ffmpeg s16le decode exactly
    assert np.array_equal(
        samples, ints.astype(np.float32) / np.float32(32768.0))
    assert samples[0] == 0.0 and samples[4] == -1.0


def test_read_pcm_wav_matches_backend_ffmpeg_decode(tmp_path):
    """The wave-module read must equal mlx-whisper's own s16le decode."""
    import subprocess
    import wave

    import numpy as np

    from transcribe.audio import read_pcm_wav

    rng = np.random.default_rng(7)
    ints = rng.integers(-32768, 32767, size=1600, dtype=np.int16)
    path = tmp_path / "noise.wav"
    with wave.open(str(path), "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(16000)
        fh.writeframes(ints.tobytes())

    from mlx_whisper.audio import load_audio as backend_load_audio
    backend = backend_load_audio(str(path))
    mine = read_pcm_wav(str(path))
    assert backend.shape == mine.shape
    assert np.allclose(np.asarray(backend), mine, atol=0, rtol=0)
