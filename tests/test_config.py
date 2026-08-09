import os
from prime_transcribe.config import Config, load, save


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
