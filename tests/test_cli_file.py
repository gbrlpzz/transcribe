"""Regression: `transcribe file` must run end-to-end (B1 - the NameError class of bug).

Drives cmd_file with a stubbed Transcriber so no MLX weights are needed, and
asserts the storage helper (write_transcript_markdown) is actually reachable.
"""

import argparse
import wave
from pathlib import Path

import pytest

import transcribe.cli as cli
from transcribe.config import Config


def _wav(tmp_path: Path) -> Path:
    p = tmp_path / "clip.wav"
    with wave.open(str(p), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes(b"\x00\x00" * 16000)
    return p


class _FakeTranscriber:
    def __init__(self, *a, **k):
        pass

    def transcribe(self, path):
        return {"text": "hello world", "language": "en", "elapsed": 0.01}


@pytest.fixture()
def fake_transcriber(monkeypatch):
    monkeypatch.setattr(cli, "Transcriber", _FakeTranscriber)


def _args(paths, json=False, no_keep=True, notify=False, background=False):
    return argparse.Namespace(paths=[str(p) for p in paths], json=json,
                              no_keep=no_keep, notify=notify,
                              background=background)


def test_cmd_file_writes_markdown(tmp_path, fake_transcriber, capsys):
    wav = _wav(tmp_path)
    rc = cli.cmd_file(_args([wav]), Config())
    assert rc == 0
    md = Path(wav).with_suffix(".md")
    assert md.exists()
    assert "hello world" in md.read_text(encoding="utf-8")


def test_cmd_file_json_output(tmp_path, fake_transcriber, capsys):
    wav = _wav(tmp_path)
    rc = cli.cmd_file(_args([wav], json=True), Config())
    assert rc == 0
    out = capsys.readouterr().out
    assert '"text": "hello world"' in out
    assert "markdown" in out


def test_cmd_file_reports_missing_file(tmp_path, fake_transcriber):
    rc = cli.cmd_file(_args([tmp_path / "nope.wav"]), Config())
    assert rc == 1
