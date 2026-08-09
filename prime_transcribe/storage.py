"""Session storage with time-to-live cleanup.

Every dictation produces a recording plus an optional sidecar JSON transcript
under ``<home>/sessions/<YYYYMMDD>/``. Old sessions are wiped automatically by
``clean()`` (run on every CLI command, on server start, and after every
dictation), so audio and transcripts never accumulate — the default TTL is 48
hours and is configurable.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Iterator

from prime_transcribe.config import default_home


def sessions_dir() -> str:
    return os.path.join(default_home(), "sessions")


@dataclass
class Session:
    id: str                 # e.g. "20260809_143012_ab12cd"
    day: str                # "20260809"
    recording: str          # absolute path to the wav ("" if deleted)
    transcript: str = ""
    created_at: float = field(default_factory=time.time)
    duration: float = 0.0
    model: str = ""
    language: str = ""
    source: str = "cli"     # "cli" | "app" | "agent"

    @property
    def meta_path(self) -> str:
        return os.path.join(sessions_dir(), self.day, f"{self.id}.json")


def _new_id() -> str:
    return time.strftime("%Y%m%d_%H%M%S") + "_" + os.urandom(3).hex()


def save_session(
    recording: str | None,
    transcript: str,
    *,
    duration: float = 0.0,
    model: str = "",
    language: str = "",
    source: str = "cli",
    keep_transcripts: bool = True,
) -> Session:
    """Move (or reference) a recording into session storage and write metadata."""
    day = time.strftime("%Y%m%d")
    sid = _new_id()
    day_dir = os.path.join(sessions_dir(), day)
    os.makedirs(day_dir, exist_ok=True)

    stored_wav = ""
    if recording and os.path.exists(recording):
        stored_wav = os.path.join(day_dir, f"{sid}.wav")
        if os.path.abspath(recording) != os.path.abspath(stored_wav):
            os.replace(recording, stored_wav)
        else:
            stored_wav = recording

    session = Session(
        id=sid, day=day, recording=stored_wav, transcript=transcript,
        created_at=time.time(), duration=duration, model=model,
        language=language, source=source,
    )
    if keep_transcripts:
        meta: dict[str, Any] = {
            "id": session.id,
            "created_at": session.created_at,
            "duration": session.duration,
            "model": session.model,
            "language": session.language,
            "source": session.source,
            "transcript": transcript,
        }
        with open(session.meta_path, "w") as fh:
            json.dump(meta, fh, indent=2)
    return session


def iter_sessions() -> Iterator[Session]:
    root = sessions_dir()
    if not os.path.isdir(root):
        return
    for day in sorted(os.listdir(root)):
        day_dir = os.path.join(root, day)
        if not os.path.isdir(day_dir):
            continue
        for name in sorted(os.listdir(day_dir)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(day_dir, name)
            try:
                with open(path) as fh:
                    meta = json.load(fh)
            except (json.JSONDecodeError, OSError):
                continue
            yield Session(
                id=meta.get("id", name[:-5]),
                day=day,
                recording=os.path.join(day_dir, meta.get("id", name[:-5]) + ".wav")
                if os.path.exists(os.path.join(day_dir, meta.get("id", name[:-5]) + ".wav"))
                else "",
                transcript=meta.get("transcript", ""),
                created_at=meta.get("created_at", 0.0),
                duration=meta.get("duration", 0.0),
                model=meta.get("model", ""),
                language=meta.get("language", ""),
                source=meta.get("source", "cli"),
            )


def clean(ttl_hours: float, dry_run: bool = False) -> list[str]:
    """Delete sessions older than ``ttl_hours``. Returns removed file paths."""
    cutoff = time.time() - ttl_hours * 3600
    removed: list[str] = []
    for session in iter_sessions():
        if session.created_at and session.created_at < cutoff:
            for path in (session.recording, session.meta_path):
                if path and os.path.exists(path):
                    if not dry_run:
                        os.remove(path)
                    removed.append(path)
    # drop empty day directories
    if not dry_run:
        root = sessions_dir()
        if os.path.isdir(root):
            for day in os.listdir(root):
                day_dir = os.path.join(root, day)
                if os.path.isdir(day_dir) and not os.listdir(day_dir):
                    os.rmdir(day_dir)
    return removed
