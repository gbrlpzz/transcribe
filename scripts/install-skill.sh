#!/usr/bin/env bash
# Install the Prime Agent skill as "transcribe" (matching the repo name).
set -euo pipefail
SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills}"
SRC="$(cd "$(dirname "$0")/../skill/transcribe" && pwd)"
DEST="$SKILL_DIR/transcribe"

mkdir -p "$SKILL_DIR"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "✓ Prime Agent skill installed at $DEST"
