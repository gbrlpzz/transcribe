"""Configuration for Transcribe.

Settings live in a single JSON file so they are easy to read, edit and share
with the native menu-bar app. On macOS the file lives under
``~/Library/Application Support/transcribe/config.json`` (Apple HIG convention
for app data); elsewhere it falls back to the XDG data directory.

Everything can be overridden with the ``TRANSCRIBE_HOME`` environment variable
(for tests and exotic setups).
"""

from __future__ import annotations

import json
import os
import platform
import sys
from dataclasses import asdict, dataclass, fields
from typing import Any


def default_home() -> str:
    """Return the Transcribe data directory for this machine."""
    override = os.environ.get("TRANSCRIBE_HOME")
    if override:
        return os.path.expanduser(override)
    if platform.system() == "Darwin":
        base = os.path.expanduser("~/Library/Application Support")
    elif sys.platform.startswith("linux"):
        base = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
    else:
        base = os.path.expanduser("~/.transcribe")
    return os.path.join(base, "transcribe")


@dataclass
class Config:
    # --- transcription -----------------------------------------------------
    model: str = "mlx-community/whisper-turbo"  # alias accepted, see engine.MODELS
    language: str = "auto"          # "auto" | "en" | "it" | any ISO code
    backend: str = "auto"           # "auto" | "mlx" | "faster"
    # --- audio -------------------------------------------------------------
    device: str = "auto"            # avfoundation input index, or "auto"
    sample_rate: int = 16000
    # --- behaviour ---------------------------------------------------------
    paste: bool = True              # paste into the focused app after transcribing
    smart_text: bool = True         # "comma" -> ","  "new line" -> newline, etc.
    cleanup_ttl_hours: float = 48.0 # delete recordings + transcripts older than this
    keep_transcripts: bool = True   # save a .json transcript next to each recording
    # --- local engine server ----------------------------------------------
    port: int = 8765
    warm_on_start: bool = True      # preload the model when the server starts
    # --- native app --------------------------------------------------------
    hotkey: str = "ctrl+space"  # Carbon modifier names + key
    paste_mode: str = "cmd-v"       # "cmd-v" (pasteboard + Cmd+V) | "keystroke"
    launch_at_login: bool = False


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
            print(f"warning: could not read {path} ({exc}); using defaults", file=sys.stderr)
    known = {f.name for f in fields(Config)}
    values = {k: v for k, v in raw.items() if k in known}
    return Config(**values)


def save(cfg: Config) -> str:
    path = config_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(asdict(cfg), fh, indent=2, sort_keys=True)
    return path
