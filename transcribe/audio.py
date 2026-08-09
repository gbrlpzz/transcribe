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
import threading
import time


def ffmpeg_path() -> str | None:
    import shutil
    return shutil.which("ffmpeg")


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


def find_input_device(preference: str = "auto") -> str:
    """Return the avfoundation device index to use for recording."""
    devices = list_input_devices()
    if not devices:
        return "0"
    if preference != "auto":
        return preference
    # prefer anything that mentions the built-in microphone
    for d in devices:
        if "built-in" in d["name"].lower() or "microphone" in d["name"].lower():
            return d["index"]
    return devices[0]["index"]


class Recorder:
    """Press-to-talk style recorder: start(), stop() -> wav path."""

    def __init__(self, device: str = "auto", sample_rate: int = 16000):
        self.device = find_input_device(device)
        self.sample_rate = sample_rate
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
             "-ac", "1", "-ar", str(self.sample_rate),
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
        duration = time.time() - self._started
        _pcm_to_wav(self._pcm_path, self._wav_path, self.sample_rate)
        os.remove(self._pcm_path)
        return self._wav_path or ""


def _pcm_to_wav(pcm_path: str, wav_path: str, sample_rate: int) -> None:
    """Wrap raw s16le PCM in a standard 44-byte WAV header."""
    with open(pcm_path, "rb") as fh:
        data = fh.read()
    n = len(data) // 2
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(data), b"WAVE",
        b"fmt ", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16,
        b"data", len(data),
    )
    with open(wav_path, "wb") as fh:
        fh.write(header)
        fh.write(data)


def record_interactive(device: str = "auto", sample_rate: int = 16000,
                       prompt: str | None = None) -> str:
    """Record until the user presses Enter; returns the WAV path."""
    if prompt is None:
        prompt = "Recording… press Enter to stop"
    rec = Recorder(device=device, sample_rate=sample_rate)
    rec.start()
    print(prompt, file=sys.stderr)
    input()
    return rec.stop()
