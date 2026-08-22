"""Microphone capture.

Uses ``ffmpeg``'s built-in AVFoundation input on macOS, so there are zero extra
dependencies beyond ffmpeg itself (``brew install ffmpeg``). Audio is captured
as raw 16 kHz mono PCM and wrapped in a standard WAV header afterwards, which
makes early stopping trivially safe (no header repair needed).
"""

from __future__ import annotations

import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import wave

SAMPLE_RATE = 16000  # Whisper's native input rate


def ffmpeg_path() -> str | None:
    import shutil
    found = shutil.which("ffmpeg")
    if found:
        return found
    # fall back to the standard Homebrew/usr locations when PATH is minimal
    # (e.g. when the engine is spawned by a GUI app)
    for candidate in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                      "/usr/bin/ffmpeg", "/opt/homebrew/opt/ffmpeg/bin/ffmpeg"):
        if os.path.exists(candidate):
            return candidate
    return None


def is_pcm_wav(path: str) -> bool:
    """Return whether *path* is already Whisper-friendly PCM WAV audio.

    The native recorder writes exactly this format. Avoiding a second ffmpeg
    normalization pass saves a subprocess, a temporary file, and a full audio
    decode before the backend decodes it once more.
    """
    try:
        with wave.open(path, "rb") as fh:
            return (
                fh.getcomptype() == "NONE"
                and fh.getnchannels() == 1
                and fh.getsampwidth() == 2
                and fh.getframerate() == SAMPLE_RATE
            )
    except (OSError, wave.Error):
        return False


def read_pcm_wav(path: str):
    """Read 16-bit PCM mono WAV into a float32 waveform scaled to [-1, 1].

    Callers must have verified the format with :func:`is_pcm_wav` first. The
    scaling matches the backend's own s16le decode byte for byte (int16 cast
    to float32, divided by 32768), so handing this array to Whisper instead
    of the file path is transcript-identical while skipping the ffmpeg
    subprocess decode entirely.
    """
    import numpy as np

    with wave.open(path, "rb") as fh:
        frames = fh.readframes(fh.getnframes())
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


def list_input_devices() -> list[dict[str, str]]:
    """Enumerate AVFoundation audio input devices via ffmpeg."""
    ff = ffmpeg_path()
    if not ff:
        return []
    try:
        proc = subprocess.run(
            [ff, "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
            capture_output=True, text=True, timeout=20,
        )
    except (subprocess.TimeoutExpired, OSError):
        return []
    stderr = proc.stderr or ""
    devices: list[dict[str, str]] = []
    for line in stderr.splitlines():
        m = re.search(r"\[\s*(\d+)\s*\]\s+(.+)", line)
        if m and ("audio" in line or "microphone" in line.lower() or "input" in line.lower()):
            devices.append({"index": m.group(1), "name": m.group(2).strip()})
    return devices


def find_input_device() -> str:
    """Return the avfoundation device index of the default microphone."""
    devices = list_input_devices()
    if not devices:
        return "0"
    # prefer anything that mentions the built-in microphone
    for d in devices:
        if "built-in" in d["name"].lower() or "microphone" in d["name"].lower():
            return d["index"]
    return devices[0]["index"]


class Recorder:
    """Press-to-talk style recorder: start(), stop() -> wav path."""

    def __init__(self):
        self.device = find_input_device()
        self._proc: subprocess.Popen | None = None
        self._pcm_path: str | None = None
        self._wav_path: str | None = None
        self._started: float = 0.0

    def start(self) -> None:
        ff = ffmpeg_path()
        if not ff:
            raise RuntimeError("ffmpeg not found — install it with `brew install ffmpeg`")
        self._pcm_path = tempfile.mktemp(suffix=".pcm")
        self._wav_path = tempfile.mktemp(suffix=".wav")
        self._proc = subprocess.Popen(
            [ff, "-hide_banner", "-loglevel", "error",
             "-f", "avfoundation", "-i", f":{self.device}",
             "-ac", "1", "-ar", str(SAMPLE_RATE),
             "-f", "s16le", self._pcm_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self._started = time.time()

    def stop(self) -> str:
        """Stop recording and return the path to a valid WAV file."""
        if not self._proc or not self._pcm_path:
            raise RuntimeError("recorder not running")
        self._proc.terminate()
        try:
            self._proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            self._proc.wait(timeout=10)
        _pcm_to_wav(self._pcm_path, self._wav_path, SAMPLE_RATE)
        os.remove(self._pcm_path)
        return self._wav_path or ""


def _pcm_to_wav(pcm_path: str, wav_path: str, sample_rate: int) -> None:
    """Wrap raw s16le PCM in a standard 44-byte WAV header."""
    with open(pcm_path, "rb") as fh:
        data = fh.read()
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(data), b"WAVE",
        b"fmt ", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16,
        b"data", len(data),
    )
    with open(wav_path, "wb") as fh:
        fh.write(header)
        fh.write(data)


def audio_to_wav(path: str) -> str:
    """Normalize any audio file to a 16 kHz mono PCM WAV via ffmpeg.

    Whisper backends are picky about container/codec combinations; routing every
    input through ffmpeg first makes file transcription reliable across m4a, mp3,
    aac, ogg, wav, etc. Returns the path to a temporary WAV (caller deletes it).

    Raises ``RuntimeError`` with an actionable message if ffmpeg is missing or the
    file cannot be decoded.
    """
    ff = ffmpeg_path()
    if not ff:
        raise RuntimeError(
            "ffmpeg not found — install it with `brew install ffmpeg` so file "
            "transcription can decode this audio"
        )
    if not os.path.exists(path):
        raise RuntimeError(f"audio file not found: {path}")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as fh:
        out = fh.name
    proc = subprocess.run(
        [ff, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", path,
         "-map", "0:a:0?", "-vn", "-sn", "-dn", "-ac", "1", "-ar", str(SAMPLE_RATE),
         "-c:a", "pcm_s16le", out],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
    )
    if proc.returncode != 0 or not os.path.exists(out) or os.path.getsize(out) == 0:
        # Clean up a possible empty/partial output before reporting failure.
        if os.path.exists(out):
            try:
                os.remove(out)
            except OSError:
                pass
        detail = " ".join((proc.stderr or "").split())
        if len(detail) > 360:
            detail = detail[-360:]
        suffix = f" ({detail})" if detail else ""
        raise RuntimeError(
            f"ffmpeg could not decode {os.path.basename(path)}{suffix} — the file may be "
            "corrupt, DRM-protected, or an unsupported format"
        )
    return out


def record_interactive(prompt: str | None = None) -> str:
    """Record until the user presses Enter; returns the WAV path."""
    if prompt is None:
        prompt = "Recording… press Enter to stop"
    rec = Recorder()
    rec.start()
    print(prompt, file=sys.stderr)
    input()
    return rec.stop()
