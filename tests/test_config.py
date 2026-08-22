import json
import os

from transcribe.config import Config, load, save


def test_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    cfg = Config()
    cfg.hotkey = "ctrl+option+space"
    cfg.port = 9000
    path = save(cfg)
    loaded = load()
    assert loaded.hotkey == "ctrl+option+space"
    assert loaded.port == 9000
    assert os.path.exists(path)


def test_retention_defaults():
    cfg = Config()
    assert cfg.live_cleanup_ttl_hours == 1.0
    assert cfg.cleanup_ttl_hours == 168.0
    assert cfg.keep_transcripts is True
    assert cfg.cleanup_interval_minutes == 30.0
    assert cfg.hotkey == "ctrl+space"
    assert cfg.port == 8765


def test_unknown_legacy_keys_are_ignored(tmp_path, monkeypatch):
    """A pre-0.5 config.json (model/language/backend/...) loads cleanly."""
    monkeypatch.setenv("TRANSCRIBE_HOME", str(tmp_path))
    legacy = {
        "model": "turbo", "language": "it", "backend": "faster",
        "device": "2", "sample_rate": 48000, "paste": False,
        "smart_text": False, "warm_on_start": False, "paste_mode": "keystroke",
        "launch_at_login": True, "hotkey": "ctrl+space", "port": 8765,
        "live_cleanup_ttl_hours": 1.0, "cleanup_ttl_hours": 168.0,
        "keep_transcripts": True,
    }
    os.makedirs(str(tmp_path), exist_ok=True)
    with open(os.path.join(str(tmp_path), "config.json"), "w") as fh:
        json.dump(legacy, fh)
    cfg = load()
    assert cfg.hotkey == "ctrl+space"
    assert cfg.live_cleanup_ttl_hours == 1.0
    assert not hasattr(cfg, "model")
    assert not hasattr(cfg, "language")
