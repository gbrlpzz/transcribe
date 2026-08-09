#!/usr/bin/env bash
# Install the Prime Agent skill as "transcribe" (matching the repo name).
# Any previous cloud-based transcription skill is removed — Transcribe is the
# fully local successor.
set -euo pipefail
SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills}"
SRC="$(cd "$(dirname "$0")/../skill/transcribe" && pwd)"
DEST="$SKILL_DIR/transcribe"

mkdir -p "$SKILL_DIR"
rm -rf "$DEST" "$SKILL_DIR/legacy-transcription"
cp -R "$SRC" "$DEST"
echo "✓ Prime Agent skill installed at $DEST"
