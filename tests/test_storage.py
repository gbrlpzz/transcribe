import os

from prime_transcribe import storage


def test_save_and_clean(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    wav = tmp_path / "rec.wav"
    wav.write_bytes(b"RIFFfake")
    session = storage.save_session(str(wav), "hello world", duration=1.5, model="m", language="en")
    assert os.path.exists(session.recording)
    assert os.path.exists(session.meta_path)

    # too young -> survives
    assert storage.clean(ttl_hours=48) == []
    # TTL 0 -> everything older than now is removed
    removed = storage.clean(ttl_hours=0)
    assert len(removed) == 2
    assert not os.path.exists(session.recording)
    assert not os.path.exists(session.meta_path)


def test_iter_sessions(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    wav = tmp_path / "a.wav"
    wav.write_bytes(b"x")
    storage.save_session(str(wav), "first")
    sessions = list(storage.iter_sessions())
    assert len(sessions) == 1
    assert sessions[0].transcript == "first"
