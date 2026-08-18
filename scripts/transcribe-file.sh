#!/usr/bin/env bash
# transcribe-file.sh — launcher used by the "Transcribe" Finder Quick Action.
# Resolves the transcribe CLI and runs file transcription detached with a
# completion notification, so you can keep dictating while it works.
set -u

REPO="$HOME/transcribe"
VENV_PY="$REPO/.venv/bin/python"

# Ensure ffmpeg / standard tools are on PATH for any subprocess.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

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

exec "${RUNNER[@]}" file --background --notify "${FILES[@]}"
