#!/usr/bin/env bash
# Install the Prime Agent skill (backs up any existing `transcribe` skill).
set -euo pipefail
SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills}"
SRC="$(cd "$(dirname "$0")/../skill/transcribe" && pwd)"
DEST="$SKILL_DIR/transcribe"

if [[ -d "$DEST" ]] && [[ ! -f "$DEST/transcribe_skill.py" ]]; then
    # an older/other skill occupies the name — keep it, install alongside as transcribe-local
    echo "→ existing $DEST is not the Transcribe skill; keeping it as legacy-transcription"
    mv "$DEST" "$SKILL_DIR/legacy-transcription" 2>/dev/null || true
fi

mkdir -p "$SKILL_DIR"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "✓ Prime Agent skill installed at $DEST"
