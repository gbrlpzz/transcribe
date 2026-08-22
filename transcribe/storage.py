"""Session storage with time-to-live cleanup.

Live dictation produces a recording plus an optional sidecar JSON transcript
under ``<home>/sessions/<YYYYMMDD>/``. File jobs keep the source in place and
track the generated Markdown beside it. ``clean()`` removes live data after a
short recovery window and file transcripts after the longer file TTL.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Iterator

from transcribe.config import default_home


def sessions_dir() -> str:
    return os.path.join(default_home(), "sessions")


@dataclass
class Session:
    id: str                 # e.g. "20260809_143012_ab12cd"
    day: str                # "20260809"
    recording: str          # absolute path to the wav ("" if deleted)
    transcript: str = ""
    created_at: float = field(default_factory=time.time)
    model: str = ""
    language: str = ""
    source: str = "cli"     # "live" | "file" | legacy "cli"/"app"/"agent"
    source_path: str = ""    # original file for a file job; never removed by cleanup
    transcript_path: str = ""  # generated file transcript, if any

    @property
    def meta_path(self) -> str:
        return os.path.join(sessions_dir(), self.day, f"{self.id}.json")


def _new_id() -> str:
    return time.strftime("%Y%m%d_%H%M%S") + "_" + os.urandom(3).hex()


def save_session(
    recording: str | None,
    transcript: str,
    *,
    model: str = "",
    language: str = "",
    source: str = "cli",
    keep_transcripts: bool = True,
    source_path: str = "",
    transcript_path: str = "",
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

    if source == "file" and source_path and not transcript_path:
        transcript_path = os.path.splitext(source_path)[0] + ".md"

    session = Session(
        id=sid, day=day, recording=stored_wav, transcript=transcript,
        created_at=time.time(), model=model,
        language=language, source=source, source_path=source_path,
        transcript_path=transcript_path,
    )
    # Keep metadata whenever there is a recording or generated file output so
    # cleanup can remove it even when transcript text retention is disabled.
    if keep_transcripts or stored_wav or session.transcript_path:
        meta: dict[str, Any] = {
            "id": session.id,
            "created_at": session.created_at,
            "model": session.model,
            "language": session.language,
            "source": session.source,
            "source_path": session.source_path,
            "transcript_path": session.transcript_path,
            "transcript": transcript if keep_transcripts else "",
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
                model=meta.get("model", ""),
                language=meta.get("language", ""),
                source=meta.get("source", "cli"),
                source_path=meta.get("source_path", ""),
                transcript_path=meta.get("transcript_path", ""),
            )


def clean(dry_run: bool = False, *,
          live_ttl_hours: float | None = None,
          file_ttl_hours: float | None = None) -> list[str]:
    """Delete expired live data and generated file transcripts.

    Everything that is not a file job is live data. File source paths are
    never removed; a session's generated ``transcript_path`` always is, so
    cleanup never leaves an orphaned Markdown beside a source file.
    """
    live_ttl_hours = 1.0 if live_ttl_hours is None else live_ttl_hours
    file_ttl_hours = 168.0 if file_ttl_hours is None else file_ttl_hours
    now = time.time()
    removed: list[str] = []
    for session in iter_sessions():
        ttl = file_ttl_hours if session.source == "file" else live_ttl_hours
        cutoff = now - ttl * 3600
        if session.created_at and session.created_at < cutoff:
            paths = [session.recording, session.meta_path, session.transcript_path]
            for path in paths:
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
