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
