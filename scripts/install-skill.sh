#!/usr/bin/env bash
# Install the agent-agnostic transcribe skill (markdown only, R48).
# Works for any skill loader that reads ~/.agents/skills/<name>/SKILL.md.
set -euo pipefail
SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills}"
SRC="$(cd "$(dirname "$0")/../skill/transcribe" && pwd)"
DEST="$SKILL_DIR/transcribe"

mkdir -p "$SKILL_DIR"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC/SKILL.md" "$DEST/SKILL.md"
echo "✓ transcribe skill installed at $DEST"
echo "  It wraps the CLI bundled in Transcribe.app (macOS 26+)."
