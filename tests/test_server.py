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
        self.calls.append("load")

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


def test_transcribe_times_out_releases_lock_and_recovers(fake_server, monkeypatch, tmp_path):
    """A slow transcriber hits REQUEST_TIMEOUT_S: the client gets a 500, the
    lock is released, and the next request proceeds even though the stuck
    thread still occupies the abandoned executor."""
    srv, fake = fake_server
    fake.hang = True
    monkeypatch.setattr(server_mod, "REQUEST_TIMEOUT_S", 0.2)
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    t0 = time.perf_counter()
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        _post_transcribe(srv, str(clip))
    elapsed = time.perf_counter() - t0

    assert excinfo.value.code == 500
    assert "timed out" in json.loads(excinfo.value.read())["error"]
    assert 0.2 <= elapsed < 5

    # the engine lock must be free again right away
    assert srv.lock.acquire(blocking=False)
    srv.lock.release()

    # and the next request proceeds: fresh executor serves it while the
    # abandoned one still runs the never-released stuck call.
    fake.hang = False
    with _post_transcribe(srv, str(clip)) as resp:
        body = json.loads(resp.read())
    assert body["text"] == "hello"
    assert len(fake.calls) == 2


def test_engine_error_still_returns_500_and_releases_lock(fake_server, tmp_path):
    """Ordinary engine failures keep the pre-timeout contract: 500 + unlock."""
    srv, fake = fake_server

    def boom(path):
        raise RuntimeError("engine exploded")

    fake.transcribe = boom
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    with pytest.raises(urllib.error.HTTPError) as excinfo:
        _post_transcribe(srv, str(clip))

    assert excinfo.value.code == 500
    assert "engine exploded" in json.loads(excinfo.value.read())["error"]
    assert srv.lock.acquire(blocking=False)
    srv.lock.release()


def test_recycle_rebuilds_model_after_n_jobs(fake_server, monkeypatch, tmp_path):
    """Long-session guard: after RELOAD_EVERY_N jobs the model is rebuilt in
    the background and the counter resets - without failing any request."""
    srv, fake = fake_server
    monkeypatch.setattr(server_mod, "RELOAD_EVERY_N", 3)
    wav = tmp_path / "a.wav"
    wav.write_bytes(b"RIFF")

    for _ in range(5):
        wav.write_bytes(b"RIFF")  # server consumes (moves) each posted file
        with _post_transcribe(srv, str(wav)) as resp:
            assert resp.status == 200

    # the recycle thread resets the counter when it rebuilds; later jobs may
    # re-count on top of the fresh model, so assert the rebuild itself
    deadline = time.time() + 5
    while time.time() < deadline and fake.calls.count("load") == 0:
        time.sleep(0.05)
    assert fake.calls.count("load") >= 1, "model should have been rebuilt"
    assert srv._jobs_since_load < server_mod.RELOAD_EVERY_N


def test_recycle_skips_while_engine_busy(fake_server, monkeypatch, tmp_path):
    """A due recycle never fights a running job: it waits for a later one."""
    srv, fake = fake_server
    monkeypatch.setattr(server_mod, "RELOAD_EVERY_N", 1)
    wav = tmp_path / "a.wav"
    wav.write_bytes(b"RIFF")

    # occupy the engine, then complete a job while the lock is held
    with srv.lock:
        assert srv.note_job_done_and_check_recycle()
        srv.recycle_if_due()
        assert srv._jobs_since_load == 1, "recycle must not reset while busy"
    # once free, the next due completion goes through
    srv.recycle_if_due()
    deadline = time.time() + 5
    while time.time() < deadline and srv._jobs_since_load != 0:
        time.sleep(0.05)
    assert srv._jobs_since_load == 0
