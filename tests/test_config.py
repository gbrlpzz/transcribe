import os
from transcribe.config import Config, load, save


def test_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    cfg = Config()
    cfg.language = "it"
    cfg.smart_text = False
    path = save(cfg)
    loaded = load()
    assert loaded.language == "it"
    assert loaded.smart_text is False
    assert os.path.exists(path)


def test_retention_defaults():
    cfg = Config()
    assert cfg.live_cleanup_ttl_hours == 1.0
    assert cfg.cleanup_ttl_hours == 168.0
