# Troubleshooting

## Quick Diagnostic: `transcribe doctor`

Run the built-in diagnostic tool first:

```bash
transcribe doctor
```

It validates:
- `ffmpeg` binary installation and path.
- Available speech recognition backends (`mlx-whisper` / `faster-whisper`).
- Working microphone hardware and permissions.
- macOS Accessibility trust for auto-pasting.

---

## Common Issues and Solutions

### 1. Permissions Keep Resetting on App Launch
macOS binds Microphone and Accessibility permissions to the app's code signature. If the app is compiled with ad-hoc signing (`codesign -s -`), every rebuild changes the signature hash, causing macOS to prompt again.

**Fix**: Always build with `make app` or `make app-install`. The build script automatically uses a stable local signing certificate if present. Grant each permission once in System Settings.

### 2. "No transcription backend installed"
Install the backend into the Python environment:

```bash
# Apple Silicon (M1/M2/M3/M4)
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe --with mlx-whisper

# Intel Macs or Linux
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe --with faster-whisper
```

### 3. Text Is Copied but Not Pasted into Apps
Auto-pasting synthesizes a `⌘V` keypress, which requires macOS Accessibility authorization.

**Fix**:
1. Open **System Settings** → **Privacy & Security** → **Accessibility**.
2. Enable **Transcribe** (for the menu-bar app) and your terminal (for the CLI).
3. If you prefer manual pasting only, disable auto-paste:
   ```bash
   transcribe config set paste false
   ```

### 4. Menu-Bar App Shows "Engine: Not Running"
The Swift app searches for the `transcribe` CLI binary in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and your active `PATH`.

**Fix**:
Ensure `transcribe` is installed globally:
```bash
uv tool install --from git+https://github.com/gbrlpzz/transcribe transcribe
```
Then click **Engine: Not Running** in the menu-bar app to restart it.

### 5. First Dictation or Model Switch Appears Frozen
When you first run Transcribe or switch to a new model (e.g. `turbo` or `large-v3-turbo`), Hugging Face downloads the model weights (~1.6 GB) to `~/.cache/huggingface/hub/`. During this one-time initial download, transcription requests wait for the download to complete before responding.

**Fix**: Subsequent dictations are fully offline and respond in ~1.0 second. You can pre-download any model ahead of time:
```bash
# Pre-download default large-v3-turbo
huggingface-cli download mlx-community/whisper-large-v3-turbo

# Pre-download English turbo
huggingface-cli download mlx-community/whisper-turbo
```

### 6. Port 8765 Conflict or Stale Engine Process
If an old engine process is still bound to port 8765 from a previous session, terminate any existing engine instances:

```bash
# Kill stale server instances
pkill -f "transcribe serve"

# Check port 8765 status
lsof -i :8765
```
Then relaunch Transcribe from Spotlight or run `transcribe serve`.

### 7. "Nothing Heard" HUD Warning
If the HUD shows "Nothing Heard" or the recording is empty:
- Speak closer to your microphone.
- Check input levels in **System Settings** → **Sound** → **Input**.
- If multiple microphones are connected, specify your preferred device index:
  ```bash
  ffmpeg -f avfoundation -list_devices true -i ""
  transcribe config set device 1
  ```

### 8. Smart Text Replaces Words You Spoke Literally
Smart text replaces spoken punctuation keywords like "comma", "period", "new line". It uses whole-word boundary matching so normal words ("the period of time") remain untouched.

To disable all smart text replacements:
```bash
transcribe config set smart_text false
```

### 9. High Memory Pressure on 8 GB Macs
If your Mac is under high memory pressure from heavy applications (e.g. IDEs, Docker, browser tabs) and dictation slows down, switch to a lighter model:

```bash
# Switch to medium (~1.5 GB RAM) or small (~1.0 GB RAM)
transcribe config set model medium
# or
transcribe config set model small
```

### 10. File Locations
- **Configuration**: `~/Library/Application Support/transcribe/config.json`
- **Session Recordings & Transcripts**: `~/Library/Application Support/transcribe/sessions/`
- **Hugging Face Model Cache**: `~/.cache/huggingface/`
