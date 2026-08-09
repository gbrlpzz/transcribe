"""Paste transcribed text into the focused app (macOS).

Two steps, both native:
1. put the text on the pasteboard (``pbcopy``),
2. send Cmd+V to the frontmost app via System Events (AppleScript).

Requires Accessibility permission for the calling process — the same
permission commercial dictation software asks for. ``doctor`` verifies it; the native app opens
System Settings on first run.
"""

from __future__ import annotations

import shutil
import subprocess
import sys

_PASTE_SCRIPT = """on run argv
    tell application "System Events" to keystroke "v" using command down
end run
"""


def copy_text(text: str) -> bool:
    """Put ``text`` on the macOS pasteboard. Returns success."""
    pbcopy = shutil.which("pbcopy")
    if not pbcopy:
        return False
    proc = subprocess.run([pbcopy], input=text.encode("utf-8"),
                          capture_output=True, timeout=10)
    return proc.returncode == 0


def paste_text(text: str) -> bool:
    """Copy ``text`` and send Cmd+V to the frontmost app."""
    if not copy_text(text):
        print("error: could not write to pasteboard (pbcopy missing)", file=sys.stderr)
        return False
    try:
        proc = subprocess.run(
            ["osascript", "-e", _PASTE_SCRIPT],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        print(f"error: paste failed ({exc}); text is on the pasteboard", file=sys.stderr)
        return False
    if proc.returncode != 0:
        msg = (proc.stderr or "").strip()
        print(f"error: paste failed ({msg}); text is on the pasteboard", file=sys.stderr)
        print("→ grant Accessibility to your terminal in System Settings → Privacy & Security", file=sys.stderr)
        return False
    return True


def check_accessibility() -> bool:
    """Heuristic check: can we control System Events right now?"""
    if not shutil.which("osascript"):
        return False
    proc = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to get name of first process'],
        capture_output=True, text=True, timeout=15,
    )
    return proc.returncode == 0 and bool((proc.stdout or "").strip())
