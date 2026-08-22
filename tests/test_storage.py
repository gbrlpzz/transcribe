import os

from transcribe import storage


def test_save_and_clean(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    wav = tmp_path / "rec.wav"
    wav.write_bytes(b"RIFFfake")
    session = storage.save_session(str(wav), "hello world", model="m", language="en")
    assert os.path.exists(session.recording)
    assert os.path.exists(session.meta_path)

    # too young -> survives
    assert storage.clean(live_ttl_hours=48, file_ttl_hours=48) == []
    # TTL 0 -> everything older than now is removed
    removed = storage.clean(live_ttl_hours=0, file_ttl_hours=0)
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


def test_legacy_app_source_sessions_fully_clean_without_orphans(tmp_path, monkeypatch):
    """v0.2/v0.3 wrote source "app" for both flows; cleanup still reclaims them."""
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    markdown = tmp_path / "old-recording.md"
    markdown.write_text("# old-recording\n\ntext\n")
    storage.save_session(
        None, "text", source="app",
        transcript_path=str(markdown),
    )
    import json
    metas = list(storage.iter_sessions())
    assert len(metas) == 1

    removed = storage.clean(live_ttl_hours=0, file_ttl_hours=0)
    assert str(markdown) in removed          # generated md never orphans
    assert not markdown.exists()
    assert not os.path.exists(metas[0].meta_path)


def test_clean_uses_separate_live_and_file_ttls_and_preserves_source(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    live_wav = tmp_path / "live.wav"
    live_wav.write_bytes(b"live")
    live = storage.save_session(str(live_wav), "temporary", source="live")

    source = tmp_path / "meeting.m4a"
    source.write_bytes(b"source")
    markdown = tmp_path / "meeting.md"
    markdown.write_text("# meeting\n\ntranscript\n")
    file_session = storage.save_session(
        None, "meeting transcript", source="file", source_path=str(source),
        transcript_path=str(markdown),
    )

    # Make both sessions old enough for the live window but not the file window.
    # The metadata timestamp, not the filesystem mtime, drives retention.
    import json
    meta = json.loads(open(live.meta_path).read())
    meta["created_at"] = 1
    with open(live.meta_path, "w") as fh:
        json.dump(meta, fh)
    os.utime(live.recording, (0, 0))

    removed = storage.clean(live_ttl_hours=1, file_ttl_hours=168)
    assert live.recording in removed
    assert live.meta_path in removed
    assert not os.path.exists(live.recording)
    assert not os.path.exists(live.meta_path)
    assert file_session.meta_path not in removed
    assert os.path.exists(file_session.meta_path)
    assert os.path.exists(markdown)
    assert os.path.exists(source)

    # File cleanup removes only the generated transcript and metadata.
    removed = storage.clean(live_ttl_hours=1, file_ttl_hours=0)
    assert str(markdown) in removed
    assert not os.path.exists(markdown)
    assert os.path.exists(source)


def test_iter_sessions_tolerates_legacy_meta_keys(tmp_path, monkeypatch):
    """Pre-0.6 metas carry a "duration" key (always 0.0, field removed in 0.6).

    The loader must keep reading old session JSONs unchanged: unknown keys
    are ignored and nothing else about the record is disturbed.
    """
    import json

    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    wav = tmp_path / "old.wav"
    wav.write_bytes(b"x")
    session = storage.save_session(str(wav), "legacy", model="m", language="en")
    meta = json.loads(open(session.meta_path).read())
    meta["duration"] = 1.5  # as written by <= 0.5.x
    meta["smart_text"] = True  # even older leftovers must be ignored too
    with open(session.meta_path, "w") as fh:
        json.dump(meta, fh)

    loaded = list(storage.iter_sessions())
    assert len(loaded) == 1
    assert loaded[0].transcript == "legacy"
    assert loaded[0].model == "m"
    assert not hasattr(loaded[0], "duration")
