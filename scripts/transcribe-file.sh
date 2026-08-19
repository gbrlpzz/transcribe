#!/usr/bin/env bash
# transcribe-file.sh — launcher used by the "Transcribe" Finder Quick Action.
# Resolves the transcribe CLI and runs file transcription detached with a
# completion notification, so you can keep dictating while it works.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="${TRANSCRIBE_REPO:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
VENV_PY="$REPO/.venv/bin/python"

# Ensure ffmpeg / standard tools are on PATH for any subprocess.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:$PATH"

# Automator launches services from the user's home directory. Change into the
# checkout before `python -m transcribe`; otherwise Python can import the
# checkout as a namespace package and miss transcribe/__init__.py.
if [ -d "$REPO" ]; then
  cd "$REPO" || exit 1
fi

# Collect the audio files: Automator may pass them as arguments ($@) or via stdin.
FILES=("$@")
if [ "${#FILES[@]}" -eq 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && FILES+=("$line")
  done
fi
if [ "${#FILES[@]}" -eq 0 ]; then
  exit 0
fi

if [ -x "$VENV_PY" ]; then
  RUNNER=("$VENV_PY" -m transcribe)
elif command -v transcribe >/dev/null 2>&1; then
  RUNNER=(transcribe)
elif command -v uv >/dev/null 2>&1; then
  RUNNER=(uv run --project "$REPO" transcribe)
else
  osascript -e 'display notification "transcribe not found - install with: uv tool install transcribe" with title "Transcribe"' 2>/dev/null
  exit 1
fi

exec "${RUNNER[@]}" file --background --notify -- "${FILES[@]}"
