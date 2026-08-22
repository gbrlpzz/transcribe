"""Server behavior tests — fake engine, real HTTP loopback, no models.

The server runs on an ephemeral 127.0.0.1 port (never the configured 8765)
with the Transcriber replaced by a fake, so these tests never touch MLX,
model weights, or the network.
"""

import json
import threading
import time
import urllib.error
import urllib.request

import pytest

from transcribe import server as server_mod


class _FakeTranscriber:
    """Stand-in for the warm engine: records calls, can hang on demand."""

    def __init__(self):
        self.model = "fake/turbo"
        self.calls = []
        self.hang = False
        self.started = threading.Event()
        self.release = threading.Event()

    @property
    def is_warm(self):
        return True

    def load(self):
        pass

    def warm(self):
        pass

    def transcribe(self, path):
        self.calls.append(path)
        self.started.set()
        if self.hang:
            self.release.wait(timeout=30)  # simulates a stuck engine call
        return {"text": "hello", "model": self.model,
                "language": "en", "elapsed": 0.01}


@pytest.fixture(name="fake_server")
def _fake_server(monkeypatch, tmp_path):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    srv = server_mod.TranscribeServer(("127.0.0.1", 0))  # port 0: ephemeral
    fake = _FakeTranscriber()
    srv.transcriber = fake
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    yield srv, fake
    fake.release.set()  # unblock a hung fake, if any, before shutdown
    srv.shutdown()
    srv.server_close()
    thread.join(timeout=5)


def _post_transcribe(srv, audio_path):
    url = f"http://127.0.0.1:{srv.server_address[1]}/transcribe"
    req = urllib.request.Request(
        url, data=json.dumps({"path": audio_path}).encode(),
        headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=30)


def _get(srv, endpoint):
    url = f"http://127.0.0.1:{srv.server_address[1]}{endpoint}"
    return urllib.request.urlopen(url, timeout=10)


def test_reload_returns_503_fast_while_engine_busy(fake_server, tmp_path):
    """A long transcription must not make /reload block: it gets an
    immediately retryable 503 instead."""
    srv, fake = fake_server
    fake.hang = True  # hold the engine lock for as long as we probe
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    job = threading.Thread(target=lambda: _post_transcribe(srv, str(clip)))
    job.start()
    assert fake.started.wait(timeout=10)  # fake now holds the engine lock

    t0 = time.perf_counter()
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        _get(srv, "/reload")
    elapsed = time.perf_counter() - t0

    assert excinfo.value.code == 503
    assert "busy" in json.loads(excinfo.value.read())["error"]
    assert elapsed < 0.100  # immediate, not queued behind the job

    fake.release.set()  # let the job finish cleanly
    job.join(timeout=10)
    assert not job.is_alive()


def test_health_stays_served_while_engine_busy(fake_server, tmp_path):
    """/health never touches the lock and must keep answering."""
    srv, fake = fake_server
    fake.hang = True
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    job = threading.Thread(target=lambda: _post_transcribe(srv, str(clip)))
    job.start()
    assert fake.started.wait(timeout=10)

    with _get(srv, "/health") as resp:
        body = json.loads(resp.read())
    assert body["status"] == "ok" and body["warm"] is True

    fake.release.set()
    job.join(timeout=10)
