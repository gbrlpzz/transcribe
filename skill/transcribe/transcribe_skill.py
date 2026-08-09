"""Prime Agent skill: fully local dictation and transcription.

Installed by the Transcribe repo (make install). Re-exports the engine API so
the agent can transcribe files and dictate without shelling out.

Functions:
    transcribe_audio(path, language="auto", model=None) -> dict
    dictate(seconds=None, paste=False) -> dict
    clean(ttl_hours=None, dry_run=False) -> list[str]
    models() -> str
    doctor() -> str
"""

from __future__ import annotations

import os
import sys

# Make the installed package importable even when the repo isn't on sys.path.
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if os.path.isdir(os.path.join(_REPO, "prime_transcribe")):
    sys.path.insert(0, _REPO)

from prime_transcribe.config import load  # noqa: E402
from prime_transcribe.engine import MODELS, available_backends, detect_backend, transcribe as _engine_transcribe  # noqa: E402
from prime_transcribe.smarttext import apply_smart_text, strip_whitespace  # noqa: E402
from prime_transcribe.storage import clean as _clean  # noqa: E402


def transcribe_audio(path: str, language: str = "auto", model: str | None = None,
                     smart_text: bool | None = None) -> dict:
    """Transcribe an audio file locally. Returns result dict with 'text'."""
    cfg = load()
    result = _engine_transcribe(
        path,
        model=model or cfg.model,
        backend=cfg.backend,
        language=language if language != "auto" else cfg.language,
    )
    text = strip_whitespace(result["text"])
    if (cfg.smart_text if smart_text is None else smart_text):
        text = apply_smart_text(text)
    result["text"] = text
    return result


def dictate(seconds: float | None = None, paste: bool = False) -> dict:
    """Record from the microphone and transcribe.

    Interactive by default: press Enter to stop. Returns the same dict shape as
    transcribe_audio plus 'recording' (session wav path, if kept).
    """
    from prime_transcribe.audio import record_interactive
    from prime_transcribe.storage import save_session

    cfg = load()
    wav = record_interactive(device=cfg.device, sample_rate=cfg.sample_rate)
    result = transcribe_audio(wav, language=cfg.language)
    try:
        session = save_session(
            wav, result["text"], duration=0.0, model=result.get("model", ""),
            language=result.get("language", ""), source="agent",
            keep_transcripts=cfg.keep_transcripts,
        )
        result["recording"] = session.recording
    except OSError:
        pass
    if paste:
        from prime_transcribe.paste import paste_text
        paste_text(result["text"])
    return result


def clean(ttl_hours: float | None = None, dry_run: bool = False) -> list[str]:
    """Remove recordings/transcripts older than the TTL. Returns removed paths."""
    cfg = load()
    return _clean(ttl_hours if ttl_hours is not None else cfg.cleanup_ttl_hours,
                  dry_run=dry_run)


def models() -> str:
    """Human-readable model table."""
    backends = available_backends()
    lines = [f"installed backends: {', '.join(backends) or 'none'}",
             f"default backend: {detect_backend(load().backend)}", ""]
    for alias, info in MODELS.items():
        lines.append(f"{alias:16s} {info['languages']}")
        for b in ("mlx", "faster"):
            lines.append(f"    {b:8s} {info[b]}  [{'installed' if b in backends else 'missing'}]")
    return "\n".join(lines)


def doctor() -> str:
    """Diagnostics summary."""
    import shutil
    from prime_transcribe.paste import check_accessibility
    from prime_transcribe.audio import find_input_device
    cfg = load()
    lines = []
    ff = shutil.which("ffmpeg")
    lines.append(f"ffmpeg: {'✓ ' + ff if ff else '✗ install with brew install ffmpeg'}")
    backends = available_backends()
    lines.append(f"backend: {', '.join(backends) or '✗ install mlx-whisper or faster-whisper'}")
    lines.append(f"microphone: avfoundation device {find_input_device(cfg.device)}")
    lines.append(f"accessibility (paste): {'✓' if check_accessibility() else '✗ grant it in System Settings'}")
    lines.append(f"config: {load.__globals__['config_path']()}")
    return "\n".join(lines)
