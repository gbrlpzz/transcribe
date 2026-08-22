"""Configuration for Transcribe.

One model, one language mode (auto), one backend. The only settings that
remain are the ones that can genuinely vary per machine: the hotkey, the local
port, and retention windows. Everything else is a constant in code.

The file lives at ``~/Library/Application Support/transcribe/config.json``
(Apple HIG convention for app data) and is shared with the native menu-bar
app. Unknown keys from older releases are ignored, so upgrading never breaks.
Everything can be overridden with the ``TRANSCRIBE_HOME`` environment variable
(for tests and exotic setups).
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, fields
from typing import Any


def default_home() -> str:
    """Return the Transcribe data directory for this machine."""
    override = os.environ.get("TRANSCRIBE_HOME")
    if override:
        return os.path.expanduser(override)
    return os.path.join(os.path.expanduser("~/Library/Application Support"), "transcribe")


@dataclass
class Config:
    # --- native app --------------------------------------------------------
    hotkey: str = "ctrl+space"  # Carbon modifier names + key
    # --- local engine server ----------------------------------------------
    port: int = 8765
    # --- retention ---------------------------------------------------------
    # Live dictation is ephemeral: keep a short recovery window so a bad paste
    # can be pasted again. File jobs use the longer, user-visible TTL below.
    live_cleanup_ttl_hours: float = 1.0
    cleanup_ttl_hours: float = 168.0  # file transcript TTL; kept as a CLI-compatible name
    # Periodic TTL sweep while the engine runs, so long-lived servers do not
    # accumulate expired recordings and transcripts between restarts.
    cleanup_interval_minutes: float = 30.0  # 0 disables the periodic sweep
    keep_transcripts: bool = True   # save a .json transcript next to each recording


DEFAULTS = Config()


def config_path() -> str:
    return os.path.join(default_home(), "config.json")


def load() -> Config:
    """Load config from disk, filling any missing keys with defaults."""
    path = config_path()
    raw: dict[str, Any] = {}
    if os.path.exists(path):
        try:
            with open(path) as fh:
                raw = json.load(fh)
        except (json.JSONDecodeError, OSError) as exc:
            print(f"warning: could not read {path} ({exc}); using defaults", file=__import__("sys").stderr)
    known = {f.name for f in fields(Config)}
    values = {k: v for k, v in raw.items() if k in known and v is not None}
    return Config(**values)


def save(cfg: Config) -> str:
    path = config_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(asdict(cfg), fh, indent=2, sort_keys=True)
    return path
