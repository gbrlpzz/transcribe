#!/usr/bin/env python
"""M0 latency baseline benchmark for the transcribe dictation pipeline.

Measures, end to end, where wall-clock time goes on this machine:

1. CLI startup        - fresh-interpreter ``import transcribe`` x3 (min/median).
2. Capture overhead   - ffmpeg AVFoundation spawn for a 0.5 s recording;
                        overhead = total wall - 0.5 s.
3. WAV wrap           - transcribe.audio._pcm_to_wav on a 5 s raw PCM buffer.
4. Paste path         - pbcopy, then System Events Cmd+V (skipped without
                        Accessibility permission).
5. Engine             - mlx-whisper turbo-q4 on a synthetic 3 s speech-like
                        tone: cold (first call, incl. model load) vs warm.
6. Local server       - GET /health and POST /transcribe roundtrips, only when
                        a server is already listening on the configured port.

Results go to bench/results/baseline.json; a markdown table is printed.

Usage: python bench/bench_baseline.py
"""

from __future__ import annotations

import json
import math
import os
import platform
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import wave
from datetime import datetime, timezone

# Hard guarantee: this benchmark must never pull models from the network.
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO_ROOT)

RESULTS_PATH = os.path.join(REPO_ROOT, "bench", "results", "baseline.json")

results: dict = {"meta": {}, "cli_import": {}, "ffmpeg_capture": {},
                 "wav_wrap": {}, "paste": {}, "engine": {}, "server": {}}


def timed(fn, *args, **kwargs):
    t0 = time.perf_counter()
    out = fn(*args, **kwargs)
    return time.perf_counter() - t0, out


def stats(runs):
    return {"runs_s": [round(r, 4) for r in runs],
            "min_s": round(min(runs), 4),
            "median_s": round(statistics.median(runs), 4)}


# ---------------------------------------------------------------- 1. CLI startup
def bench_cli_import(runs: int = 3) -> None:
    times = []
    for _ in range(runs):
        dt, proc = timed(subprocess.run,
                         [sys.executable, "-c", "import transcribe"],
                         capture_output=True, timeout=60)
        if proc.returncode != 0:
            results["cli_import"] = {"status": "error",
                                     "stderr": proc.stderr.decode()[-300:]}
            return
        times.append(dt)
    results["cli_import"] = {"status": "ok", "command": "import transcribe",
                             **stats(times)}


# ----------------------------------------------------------- 2. capture overhead
def bench_ffmpeg_capture(seconds: float = 0.5, runs: int = 2) -> None:
    from transcribe.audio import ffmpeg_path, find_input_device
    ff = ffmpeg_path()
    if not ff:
        results["ffmpeg_capture"] = {"status": "skipped", "reason": "ffmpeg not found"}
        return
    entries, detail = [], None
    for attempt in (":0", find_input_device("auto")):  # fall back to detected index
        ok = True
        for _ in range(runs):
            fd, pcm = tempfile.mkstemp(suffix=".pcm")
            os.close(fd)
            cmd = [ff, "-hide_banner", "-loglevel", "error", "-y",
                   "-f", "avfoundation", "-i", f":{attempt}",
                   "-t", str(seconds), "-ac", "1", "-ar", "16000",
                   "-f", "s16le", pcm]
            dt, proc = timed(subprocess.run, cmd,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                             text=True, timeout=30)
            got_audio = os.path.exists(pcm) and os.path.getsize(pcm) > 0
            if os.path.exists(pcm):
                os.remove(pcm)
            if proc.returncode != 0 or not got_audio:
                detail = (proc.stderr or "").strip()[-200:]
                ok = False
                break
            entries.append({"total_s": round(dt, 4),
                            "overhead_s": round(dt - seconds, 4)})
        if ok:
            break
    if not entries:
        results["ffmpeg_capture"] = {"status": "skipped",
                                     "reason": f"capture failed: {detail}"}
        return
    overs = [e["overhead_s"] for e in entries]
    results["ffmpeg_capture"] = {"status": "ok", "device": attempt,
                                 "recording_s": seconds, "entries": entries,
                                 "overhead_median_s": round(statistics.median(overs), 4)}


# ------------------------------------------------------------------ 3. WAV wrap
def bench_wav_wrap(buffer_seconds: float = 5.0, runs: int = 10) -> None:
    from transcribe.audio import _pcm_to_wav
    n_bytes = int(16000 * 2 * buffer_seconds)
    fd, pcm = tempfile.mkstemp(suffix=".pcm")
    os.close(fd)
    with open(pcm, "wb") as fh:
        fh.write(b"\x00\x01" * (n_bytes // 2))
    wav = pcm.replace(".pcm", ".wav")
    times = []
    try:
        for _ in range(runs):
            dt, _ = timed(_pcm_to_wav, pcm, wav, 16000)
            times.append(dt)
    finally:
        for p in (pcm, wav):
            if os.path.exists(p):
                os.remove(p)
    results["wav_wrap"] = {"status": "ok", "buffer_s": buffer_seconds,
                           "bytes": n_bytes, **stats(times)}


# --------------------------------------------------------------- 4. paste path
def bench_paste() -> None:
    from transcribe.paste import check_accessibility, copy_text
    text = "Transcribe M0 baseline benchmark paste test - this text is safe to ignore. " * 1
    text = text[:100]
    accessible = False
    try:
        accessible = check_accessibility()
    except Exception:
        pass
    out = {"status": "ok", "chars": len(text), "accessibility": accessible}
    if not shutil_which("pbcopy"):
        out.update(status="skipped", reason="pbcopy missing")
        results["paste"] = out
        return
    dt_copy, ok = timed(copy_text, text)
    out["pbcopy_s"] = round(dt_copy, 4)
    out["pbcopy_ok"] = bool(ok)
    if not accessible:
        out.update(osascript="skipped",
                   reason="Accessibility permission missing for this process")
    else:
        script = ('on run argv\n    tell application "System Events" '
                  'to keystroke "v" using command down\nend run\n')
        try:
            dt_paste, proc = timed(subprocess.run,
                                   ["osascript", "-e", script],
                                   capture_output=True, text=True, timeout=15)
            out["osascript_s"] = round(dt_paste, 4)
            if proc.returncode != 0:
                out.update(osascript="failed",
                           reason=(proc.stderr or "").strip()[:200])
        except (subprocess.TimeoutExpired, OSError) as exc:
            out.update(osascript="failed", reason=str(exc)[:200])
    results["paste"] = out


def shutil_which(name):
    import shutil
    return shutil.which(name)


# ------------------------------------------------------------------ 5. engine
def make_speech_like_wav(path: str, seconds: float = 3.0, sr: int = 16000) -> None:
    """Sum of modulated sines: syllable-rate envelope + formant-ish partials."""
    frames = bytearray()
    n = int(sr * seconds)
    for i in range(n):
        t = i / sr
        env = max(0.0, math.sin(2 * math.pi * 2.5 * t))          # speech/pause rhythm
        jitter = 0.7 + 0.3 * math.sin(2 * math.pi * 11 * t)
        v = (0.55 * math.sin(2 * math.pi * 170 * t)
             + 0.30 * math.sin(2 * math.pi * 700 * t) * (0.5 + 0.5 * math.sin(2 * math.pi * 4 * t))
             + 0.18 * math.sin(2 * math.pi * 1220 * t))
        sample = int(9000 * env * jitter * v)
        sample = max(-32767, min(32767, sample))
        frames += struct.pack("<h", sample)
    with wave.open(path, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(sr)
        fh.writeframes(bytes(frames))


def bench_engine() -> str | None:
    """Returns the wav path on success so the server bench can reuse it."""
    try:
        import mlx_whisper  # noqa: F401
    except ImportError:
        results["engine"] = {"status": "skipped", "reason": "mlx-whisper not installed"}
        return None
    from huggingface_hub import snapshot_download
    from transcribe.engine import DEFAULT_MODEL, MODELS, Transcriber
    repo = MODELS[DEFAULT_MODEL]["mlx"]
    lid_repo = "mlx-community/whisper-tiny"
    missing = []
    for r in (repo, lid_repo):
        try:
            snapshot_download(repo_id=r, local_files_only=True)
        except Exception as exc:  # noqa: BLE001
            missing.append(f"{r}: {type(exc).__name__}")
    if missing:
        results["engine"] = {"status": "skipped",
                             "reason": "model not cached, download required",
                             "missing": missing}
        return None

    fd, wav = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    make_speech_like_wav(wav, 3.0)
    tr = Transcriber(model=DEFAULT_MODEL, backend="mlx", language="auto")
    cold_t, cold = timed(tr.transcribe, wav)
    warm_t, warm = timed(tr.transcribe, wav)
    results["engine"] = {
        "status": "ok", "backend": tr.backend, "model": tr.model,
        "audio_s": 3.0, "cold_s": round(cold_t, 4), "warm_s": round(warm_t, 4),
        "warm_reported_elapsed_s": warm.get("elapsed"),
        "language_detected": warm.get("language"),
        "text_sample": (warm.get("text") or "")[:80],
    }
    return wav


# ----------------------------------------------------------------- 6. server
def bench_server(wav: str | None) -> None:
    from transcribe.config import load
    port = load().port
    base = f"http://127.0.0.1:{port}"
    try:
        with urllib.request.urlopen(f"{base}/health", timeout=2) as resp:
            health = json.loads(resp.read().decode())
    except Exception as exc:  # noqa: BLE001
        results["server"] = {"status": "skipped",
                             "reason": f"no server on port {port}: {type(exc).__name__}"}
        return
    health_times = []
    for _ in range(3):
        dt, _ = timed(lambda: urllib.request.urlopen(f"{base}/health", timeout=5).read())
        health_times.append(dt)
    out = {"status": "ok", "url": base, "health": health,
           "health_roundtrip": stats(health_times)}
    if wav and os.path.exists(wav):
        # preserve_source keeps the server from moving our file into session
        # storage (live-mode POSTs consume the recording via os.replace).
        payload = json.dumps({"path": wav, "preserve_source": True}).encode()
        req_times, last = [], None
        for _ in range(2):
            def post():
                req = urllib.request.Request(
                    f"{base}/transcribe", data=payload,
                    headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return json.loads(resp.read().decode())
            dt, last = timed(post)
            req_times.append(dt)
        out["transcribe_warm"] = {**stats(req_times),
                                  "text_sample": (last.get("text") or "")[:80],
                                  "language": last.get("language")}
    results["server"] = out


def main() -> None:
    results["meta"] = {
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "transcribe_version": _version(),
    }
    t_start = time.perf_counter()
    bench_cli_import()
    bench_ffmpeg_capture()
    bench_wav_wrap()
    bench_paste()
    wav = bench_engine()
    bench_server(wav)
    if wav and os.path.exists(wav):
        os.remove(wav)
    if wav:  # file-job POSTs leave a transcript markdown next to the source
        side_md = os.path.splitext(wav)[0] + ".md"
        if os.path.exists(side_md):
            os.remove(side_md)
    results["meta"]["total_bench_s"] = round(time.perf_counter() - t_start, 2)

    os.makedirs(os.path.dirname(RESULTS_PATH), exist_ok=True)
    with open(RESULTS_PATH, "w") as fh:
        json.dump(results, fh, indent=2)
    print(json.dumps(results, indent=2))
    print("\n" + markdown_table())


def _version() -> str:
    try:
        from transcribe import __version__
        return __version__
    except Exception:
        return "unknown"


def markdown_table() -> str:
    c, f, w, p, e, s = (results.get(k, {}) for k in
                        ("cli_import", "ffmpeg_capture", "wav_wrap",
                         "paste", "engine", "server"))
    rows = [
        ("CLI startup (`import transcribe`, fresh interp)",
         f"{c.get('min_s')} s min / {c.get('median_s')} s median (n={len(c.get('runs_s', []))})"
         if c.get("min_s") is not None else c.get("status", "n/a")),
        ("Capture overhead (ffmpeg spawn, 0.5 s rec)",
         f"{f.get('overhead_median_s')} s median (n={len(f.get('entries', []))})"
         if f.get("status") == "ok" else f"skipped: {f.get('reason', '')}"),
        ("WAV header wrap (5 s PCM)",
         f"{w.get('min_s')} s min / {w.get('median_s')} s median"
         if w.get("min_s") is not None else w.get("status", "n/a")),
        ("Paste: pbcopy", f"{p.get('pbcopy_s')} s" if p.get("pbcopy_s") is not None
         else p.get("reason", "n/a")),
        ("Paste: System Events Cmd+V",
         f"{p.get('osascript_s')} s" if isinstance(p.get("osascript_s"), float)
         else p.get("reason", p.get("osascript", "n/a"))),
        ("Engine cold (load + transcribe, 3 s tone)",
         f"{e.get('cold_s')} s ({e.get('model')})" if e.get("status") == "ok"
         else f"{e.get('status')}: {e.get('reason', '')}"),
        ("Engine warm (2nd call, same process)",
         f"{e.get('warm_s')} s" if e.get("status") == "ok" else "-"),
        ("Server GET /health roundtrip",
         f"{s.get('health_roundtrip', {}).get('median_s')} s median"
         if s.get("status") == "ok" else f"skipped: {s.get('reason', '')}"),
        ("Server POST /transcribe (warm)",
         f"{s.get('transcribe_warm', {}).get('median_s')} s median"
         if s.get("transcribe_warm") else "-"),
    ]
    lines = ["| Stage | Latency |", "|---|---|"]
    lines += [f"| {a} | {b} |" for a, b in rows]
    lines.append("")
    lines.append(f"Total benchmark wall time: {results['meta'].get('total_bench_s')} s "
                 f"- results: bench/results/baseline.json")
    return "\n".join(lines)


if __name__ == "__main__":
    main()
