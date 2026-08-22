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


# --- dual-lane tests (b-dual) -------------------------------------------
# Same contract as above: fake engines only, ephemeral ports. These cover the
# overflow lane: lazy creation on dictation-during-busy, file-kind 503,
# idle eviction, per-lane timeouts, and per-lane recycling.

@pytest.fixture(name="dual_server")
def _dual_server(monkeypatch, tmp_path):
    """Server whose every lane gets a fresh fake transcriber.

    made[0] is always the primary lane's fake; later entries are overflow
    lanes in creation order. All fakes are un-hung at teardown.
    """
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    made = []

    def _factory():
        fake = _FakeTranscriber()
        made.append(fake)
        return fake

    monkeypatch.setattr(server_mod, "Transcriber", _factory)
    srv = server_mod.TranscribeServer(("127.0.0.1", 0))  # ephemeral, never 8765
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    yield srv, made
    for fake in made:
        fake.release.set()  # unblock any hung fake before shutdown
    srv.shutdown()
    srv.server_close()
    thread.join(timeout=5)


def _post_json(srv, payload):
    url = f"http://127.0.0.1:{srv.server_address[1]}/transcribe"
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=30)


def _health_lanes(srv):
    with _get(srv, "/health") as resp:
        return json.loads(resp.read())["lanes"]


def test_dictation_spills_to_overflow_while_file_holds_primary(dual_server,
                                                               tmp_path):
    """THE core scenario: a hung file job owns the primary lane; a plain
    dictation body (no kind, preserve_source absent -> dictation) must still
    succeed via the lazily created overflow lane."""
    srv, made = dual_server
    primary = made[0]
    primary.hang = True
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    job = threading.Thread(
        target=lambda: _post_json(srv, {"path": str(clip),
                                        "preserve_source": True}))
    job.start()
    assert primary.started.wait(timeout=10)  # primary lane now occupied

    assert _health_lanes(srv) == {"primary": True, "overflow": False}
    with _post_json(srv, {"path": str(clip)}) as resp:  # dictation body
        body = json.loads(resp.read())
    assert body["text"] == "hello"

    assert len(made) == 2, "exactly one overflow lane should exist"
    overflow = made[1]
    assert overflow.calls == [str(clip)], "dictation ran on the overflow lane"
    assert primary.calls == [str(clip)], "dictation must not touch the primary"
    assert _health_lanes(srv) == {"primary": True, "overflow": True}

    primary.release.set()
    job.join(timeout=10)
    assert not job.is_alive()


def test_file_job_while_busy_keeps_immediate_503_and_no_overflow(dual_server,
                                                                 tmp_path):
    """File-kind traffic never spills: same immediate 503 as today, and the
    collision must not spin up an overflow lane."""
    srv, made = dual_server
    primary = made[0]
    primary.hang = True
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    job = threading.Thread(
        target=lambda: _post_json(srv, {"path": str(clip),
                                        "kind": "file"}))
    job.start()
    assert primary.started.wait(timeout=10)

    t0 = time.perf_counter()
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        # file inference also works via preserve_source=true, no kind field
        _post_json(srv, {"path": str(clip), "preserve_source": True})
    elapsed = time.perf_counter() - t0
    assert excinfo.value.code == 503
    assert "busy" in json.loads(excinfo.value.read())["error"]
    assert elapsed < 0.5

    assert srv._overflow is None, "file traffic must not create an overflow"
    assert len(made) == 1
    assert _health_lanes(srv)["overflow"] is False

    primary.release.set()
    job.join(timeout=10)


def test_invalid_kind_is_rejected_with_400(dual_server, tmp_path):
    srv, _made = dual_server
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        _post_json(srv, {"path": str(clip), "kind": "banana"})
    assert excinfo.value.code == 400


def test_no_overlap_never_creates_overflow_and_response_shape_unchanged(
        dual_server, tmp_path):
    """Steady state: sequential requests behave exactly like the old single
    server - primary lane only, no overflow, same response keys."""
    srv, made = dual_server
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    for _ in range(3):
        clip.write_bytes(b"RIFFfake")  # server consumes (moves) each posting
        with _post_json(srv, {"path": str(clip)}) as resp:
            body = json.loads(resp.read())
        assert sorted(body) == ["elapsed", "language", "model", "text",
                                "transcript_path"]
        assert _health_lanes(srv) == {"primary": True, "overflow": False}
    assert srv._overflow is None
    assert made[0].calls.count(str(clip)) == 3
    assert len(made) == 1


def test_overflow_evicts_after_idle_threshold(dual_server):
    """Idle overflow is torn down (short injected threshold), restoring the
    single-lane state; a busy overflow lane survives the sweep."""
    srv, made = dual_server
    assert srv.evict_idle_overflow() is False  # nothing to evict

    with srv.primary.lock:  # simulate a busy primary lane
        lane, err = srv.acquire_lane("dictation")
        assert lane is not None and err == ""
        assert len(made) == 2  # overflow lazily created here

        srv.overflow_idle_s = 0.05
        time.sleep(0.15)  # past the threshold, but the lane is mid-"job"

        assert srv.evict_idle_overflow() is False, "busy lane must survive"
        assert srv._overflow is lane
        lane.lock.release()

    assert srv.evict_idle_overflow() is True
    assert srv._overflow is None
    assert srv.evict_idle_overflow() is False  # already gone


def test_health_reports_overflow_presence_across_lifecycle(dual_server,
                                                           tmp_path):
    """/health lanes flag tracks create->evict; existing fields unchanged."""
    srv, made = dual_server
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    with _get(srv, "/health") as resp:
        body = json.loads(resp.read())
    assert body["status"] == "ok" and body["warm"] is True
    assert body["model"] == "fake/turbo"
    assert body["lanes"] == {"primary": True, "overflow": False}

    with srv.primary.lock:
        lane, _err = srv.acquire_lane("dictation")
        lane.lock.release()
    assert _health_lanes(srv)["overflow"] is True

    srv.overflow_idle_s = 0.05
    time.sleep(0.15)
    assert srv.evict_idle_overflow() is True
    assert _health_lanes(srv)["overflow"] is False


def test_each_lane_times_out_independently(dual_server, monkeypatch, tmp_path):
    """A stuck overflow call costs only the overflow lane: the client gets a
    500, the overflow lock is released, and the primary lane keeps serving."""
    srv, made = dual_server
    primary, overflow = made[0], None
    monkeypatch.setattr(server_mod, "REQUEST_TIMEOUT_S", 0.2)
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    # 1) primary lane stuck on a file job -> 500, primary lock freed.
    primary.hang = True
    t0 = time.perf_counter()
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        _post_json(srv, {"path": str(clip), "kind": "file"})
    assert excinfo.value.code == 500
    assert 0.2 <= time.perf_counter() - t0 < 5
    assert srv.lock.acquire(blocking=False)
    srv.lock.release()

    # 2) dictation spilled to an ALSO-stuck overflow lane -> own 500 + unlock.
    with srv.primary.lock:  # keep primary occupied so dictation spills
        lane, _err = srv.acquire_lane("dictation")
        assert lane is not None
        lane.lock.release()  # the spill request must be able to lock it
        overflow = made[1]
        overflow.hang = True

        def _spill():
            try:
                _post_json(srv, {"path": str(clip)})
            except urllib.error.HTTPError as exc:
                assert exc.code == 500

        worker = threading.Thread(target=_spill)
        worker.start()
        assert overflow.started.wait(timeout=10)
        worker.join(timeout=10)  # 500 arrives after the 0.2s lane timeout
        assert not worker.is_alive()
        assert lane.lock.acquire(blocking=False), "overflow must be unlocked"
        lane.lock.release()

    # 3) both lanes recover afterwards.
    primary.hang = False
    overflow.hang = False
    with _post_json(srv, {"path": str(clip)}) as resp:
        assert json.loads(resp.read())["text"] == "hello"


def test_overflow_recycles_on_its_own_counter(dual_server, monkeypatch):
    """RELOAD_EVERY_N counts per lane: heavy overflow use rebuilds the
    overflow model and leaves the primary model untouched."""
    srv, made = dual_server
    monkeypatch.setattr(server_mod, "RELOAD_EVERY_N", 2)

    with srv.primary.lock:  # force every request onto the overflow lane
        due_flags = []
        deadline = time.time() + 5
        while len(due_flags) < 3 and time.time() < deadline:
            lane, _err = srv.acquire_lane("dictation")
            if lane is None:
                continue  # transient 503: the lane is mid-recycle (real)
            lane.lock.release()
            due_flags.append(lane.note_job_done())
            if due_flags[-1]:  # the handler does exactly this after a job
                lane.recycle_if_due()
        # due exactly at RELOAD_EVERY_N; later flags may race the async reset
        # (same tolerance as the primary-lane recycle test above)
        assert due_flags[:2] == [False, True], "due exactly at RELOAD_EVERY_N"

        # A recycle that found the lane locked stays due; the next completion
        # retries it - reproduce that production retry here.
        lane, _err = srv.acquire_lane("dictation")
        assert lane is not None
        lane.lock.release()
        if lane.note_job_done():
            lane.recycle_if_due()

    overflow = made[1]
    primary = made[0]
    deadline = time.time() + 5
    while time.time() < deadline and overflow.calls.count("load") == 0:
        time.sleep(0.05)
    assert overflow.calls.count("load") >= 1, "overflow model rebuilt"
    assert primary.calls.count("load") == 0, "primary must stay untouched"
    assert srv._jobs_since_load == 0  # primary counter never moved
