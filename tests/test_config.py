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


def test_legacy_turbo_model_migrates_to_quantized_default(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    save(Config(model="turbo"))
    assert load().model == "turbo-q4"


def test_explicit_model_choice_survives_load(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    save(Config(model="turbo-q8"))
    assert load().model == "turbo-q8"


def test_cleanup_interval_default():
    cfg = Config()
    assert cfg.cleanup_interval_minutes == 30.0
