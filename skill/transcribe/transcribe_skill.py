"""Prime Agent skill: fully local dictation and transcription.

Installed by the Transcribe repo (make install). Re-exports the engine API so
the agent can transcribe files and dictate without shelling out.

Functions:
    transcribe_audio(path) -> dict
    dictate(seconds=None, paste=False) -> dict
    clean(ttl_hours=None, dry_run=False) -> list[str]
    doctor() -> str
"""

from __future__ import annotations

import os
import sys

# Make the installed package importable even when the repo isn't on sys.path.
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if os.path.isdir(os.path.join(_REPO, "transcribe")):
    sys.path.insert(0, _REPO)

from transcribe.config import config_path, load  # noqa: E402
from transcribe.engine import transcribe as _engine_transcribe  # noqa: E402
from transcribe.smarttext import apply_smart_text, strip_whitespace  # noqa: E402
from transcribe.storage import clean as _clean  # noqa: E402


def transcribe_audio(path: str, smart_text: bool | None = None) -> dict:
    """Transcribe an audio file locally (auto language). Returns result dict."""
    result = _engine_transcribe(path)
    text = strip_whitespace(result["text"])
    if smart_text is None or smart_text:
        text = apply_smart_text(text)
    result["text"] = text
    return result


def dictate(seconds: float | None = None, paste: bool = False) -> dict:
    """Record from the microphone and transcribe.

    Interactive by default: press Enter to stop. Returns the same dict shape as
    transcribe_audio plus 'recording' (session wav path, if kept).
    """
    from transcribe.audio import record_interactive
    from transcribe.storage import save_session

    cfg = load()
    wav = record_interactive()
    result = transcribe_audio(wav)
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
        from transcribe.paste import paste_text
        paste_text(result["text"])
    return result


def clean(ttl_hours: float | None = None, dry_run: bool = False) -> list[str]:
    """Remove expired live data and file transcripts. Returns removed paths."""
    cfg = load()
    return _clean(ttl_hours, dry_run=dry_run,
                  live_ttl_hours=cfg.live_cleanup_ttl_hours,
                  file_ttl_hours=cfg.cleanup_ttl_hours)


def doctor() -> str:
    """Diagnostics summary."""
    import shutil
    from transcribe.paste import check_accessibility
    from transcribe.audio import find_input_device

    lines = []
    ff = shutil.which("ffmpeg")
    lines.append(f"ffmpeg: {'✓ ' + ff if ff else '✗ install with brew install ffmpeg'}")
    try:
        import mlx_whisper  # noqa: F401
        lines.append("mlx-whisper: ✓")
    except ImportError:
        lines.append("mlx-whisper: ✗ reinstall with `make install`")
    lines.append(f"microphone: avfoundation device {find_input_device()}")
    lines.append(f"accessibility (paste): {'✓' if check_accessibility() else '✗ grant it in System Settings'}")
    lines.append(f"config: {config_path()}")
    return "\n".join(lines)
