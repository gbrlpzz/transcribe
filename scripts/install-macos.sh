#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/Library/Application Support/transcribe"
AGENT_DIR="${HOME}/Library/LaunchAgents"
ENGINE_LABEL="com.gbrlpzz.transcribe.engine"
DAEMON_LABEL="com.gbrlpzz.transcribe.daemon"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this installer supports macOS only" >&2
  exit 1
fi

for command in uv zig ffmpeg; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: missing '$command'. Install it first (Homebrew: brew install $command)." >&2
    exit 1
  fi
done

unload_agent() {
  local label="$1"
  local attempt
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ! launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
}

# Stop the old generation before uv replaces its executable symlinks. This
# prevents KeepAlive from launching a half-installed engine during upgrades.
unload_agent "com.gbrlpzz.transcribed"
unload_agent "$ENGINE_LABEL"
unload_agent "$DAEMON_LABEL"
rm -f "$AGENT_DIR/com.gbrlpzz.transcribed.plist"

mkdir -p "$BIN_DIR" "$APP_DIR" "$AGENT_DIR"

if [[ "$(uname -m)" == "arm64" ]]; then
  BACKEND_ARGS=(--with mlx==0.32.1 --with mlx-whisper==0.4.3)
else
  BACKEND_ARGS=(--with faster-whisper)
fi

echo "→ installing the local engine"
uv tool install "${BACKEND_ARGS[@]}" --force --reinstall "$ROOT"

if [[ ! -x "$BIN_DIR/transcribe-engine" ]]; then
  echo "error: uv did not install transcribe-engine" >&2
  exit 1
fi

echo "→ building the native daemon"
(
  cd "$ROOT/daemon"
  zig build -Doptimize=ReleaseFast
)

# uv owns a symlink called transcribe. Replace only that public entrypoint with
# the native binary; keep transcribe-engine as the private Python backend.
rm -f "$BIN_DIR/transcribe"
cp "$ROOT/daemon/zig-out/bin/transcribe" "$BIN_DIR/transcribe"
chmod 755 "$BIN_DIR/transcribe"
rm -f "$BIN_DIR/transcribed"

cat > "$APP_DIR/engine-launch.sh" <<SCRIPT
#!/bin/bash
set -e
export HOME=$(printf '%q' "$HOME")
export PATH=$(printf '%q' "/opt/homebrew/bin:/usr/local/bin:${BIN_DIR}:/usr/bin:/bin")
export PYTHONUNBUFFERED=1
exec $(printf '%q' "$BIN_DIR/transcribe-engine") serve
SCRIPT
chmod 755 "$APP_DIR/engine-launch.sh"

cat > "$AGENT_DIR/${ENGINE_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${ENGINE_LABEL}</string>
  <key>ProgramArguments</key><array><string>${APP_DIR}/engine-launch.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/tmp/transcribe-engine.log</string>
  <key>StandardErrorPath</key><string>/tmp/transcribe-engine.log</string>
</dict></plist>
PLIST

cat > "$AGENT_DIR/${DAEMON_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${DAEMON_LABEL}</string>
  <key>ProgramArguments</key><array><string>${BIN_DIR}/transcribe</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/tmp/transcribe-daemon.log</string>
  <key>StandardErrorPath</key><string>/tmp/transcribe-daemon.log</string>
</dict></plist>
PLIST

# The agents were unloaded before installation; load the final names.
load_agent() {
  local label="$1"
  local plist="$2"
  local attempt
  for attempt in 1 2 3; do
    if launchctl bootstrap "gui/$(id -u)" "$plist"; then
      return 0
    fi
    # launchd can take a moment to finish unloading the previous generation.
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    sleep 0.5
  done
  echo "error: launchctl could not load ${label}" >&2
  return 1
}

# Start verification from clean logs, so stale failures cannot hide a good install.
: > /tmp/transcribe-engine.log
: > /tmp/transcribe-daemon.log
load_agent "$ENGINE_LABEL" "$AGENT_DIR/${ENGINE_LABEL}.plist"
load_agent "$DAEMON_LABEL" "$AGENT_DIR/${DAEMON_LABEL}.plist"

# Keep the Finder workflow as a supported path.
mkdir -p "$HOME/Library/Services"
rm -rf "$HOME/Library/Services/Transcribe.workflow"
cp -R "$ROOT/Transcribe.workflow" "$HOME/Library/Services/"

# Keep the optional local skill install in the same one-command setup.
bash "$ROOT/scripts/install-skill.sh"

# Do not report success while launchd is still replacing the engine socket.
engine_ready=0
for attempt in $(seq 1 60); do
  if "$BIN_DIR/transcribe" ping >/dev/null 2>&1; then
    engine_ready=1
    break
  fi
  sleep 0.5
done
if [[ "$engine_ready" != 1 ]]; then
  echo "error: the engine did not expose its streaming socket" >&2
  echo "see /tmp/transcribe-engine.log" >&2
  exit 1
fi

printf '\n✓ installed %s\n' "$($BIN_DIR/transcribe --version 2>&1 | head -1)"
printf '  engine:  %s\n' "$BIN_DIR/transcribe-engine"
printf '  daemon:  %s\n' "$BIN_DIR/transcribe"
printf '  socket:  %s\n' "$APP_DIR/dictation.sock"
printf '\nGrant Microphone and Accessibility access to %s.\n' "$BIN_DIR/transcribe"
printf 'If macOS reserves ⌃␣, grant Input Monitoring or use the automatic ⌃⌥␣ fallback.\n'
