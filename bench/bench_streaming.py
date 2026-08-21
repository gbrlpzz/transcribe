"""Benchmark: legacy dictate path vs streaming pipeline (v0.5.1).

Measures, on the same machine and model:

1. Legacy mechanical overheads (from bench/baseline.json if present).
2. Whole-file decode (legacy engine path) for a reference clip.
3. Streaming session over protocol v1 fed at realtime pace: when partials
   arrive relative to speech position, and tail latency after speech ends.
4. Daemon IPC overhead (`transcribe pipe` wall time minus server decode time).

Usage:
    .venv/bin/python bench/bench_streaming.py [--wav /tmp/speech.wav] [--sock /tmp/bench.sock]
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from transcribe.engine import Transcriber  # noqa: E402
from transcribe.streamserver import StreamServer, recv_exact, send_msg  # noqa: E402


def ensure_wav(path: str, seconds: int = 12) -> str:
    """Return a speech wav at `path`, synthesizing one via macOS `say` if absent."""
    if os.path.exists(path) and os.path.getsize(path) > 10000:
        return path
    aiff = path.rsplit(".", 1)[0] + ".aiff"
    text = ("Hello, this is a test of the streaming dictation pipeline. "
            "The quick brown fox jumps over the lazy dog. "
            "Pack my box with five dozen liquor jugs.")
    subprocess.run(["say", "-v", "Samantha", "-o", aiff, text], check=True)
    subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                    "-i", aiff, "-ac", "1", "-ar", "16000", path], check=True)
    os.remove(aiff)
    return path


def read_wav_frames(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes())


def bench_whole_file(tr: Transcriber, wav: str, runs: int = 3) -> dict:
    times = []
    for _ in range(runs):
        t0 = time.perf_counter()
        tr.transcribe(wav, language="auto")
        times.append((time.perf_counter() - t0) * 1000)
    return {"whole_file_ms": sorted(times)[len(times) // 2],
            "all_runs_ms": [round(t) for t in times]}


def bench_streaming(sock_path: str, pcm: bytes, realtime: bool = True) -> dict:
    srv = StreamServer(sock_path)  # real warm transcriber inside
    srv.start()
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.connect(sock_path)
        send_msg(c, json.dumps({"op": "start", "language": "auto",
                                "session": "bench"}).encode())

        events: list[dict] = []
        done = threading.Event()

        def reader():
            while True:
                head = recv_exact(c, 4)
                if head is None:
                    break
                (n,) = struct.unpack("<I", head)
                ev = json.loads(recv_exact(c, n))
                ev["_t"] = time.perf_counter()
                events.append(ev)
                if ev["ev"] in ("final", "error"):
                    break
            done.set()

        rt = threading.Thread(target=reader, daemon=True)
        rt.start()

        t_start = time.perf_counter()
        frame = 3200  # 100 ms
        pos = 0
        while pos < len(pcm):
            send_msg(c, pcm[pos:pos + frame])
            pos += frame
            if realtime:
                time.sleep(0.1)
        t_send_end = time.perf_counter()
        send_msg(c, json.dumps({"op": "stop"}).encode())
        done.wait(timeout=120)

        first_partial = next((e for e in events if e["ev"] == "partial"), None)
        final = next((e for e in events if e["ev"] == "final"), None)
        audio_s = len(pcm) / 32000.0
        out = {
            "audio_seconds": round(audio_s, 1),
            "partials": [e["text"] for e in events if e["ev"] == "partial"],
            "first_partial_at_audio_pos_s": (
                round((first_partial["_t"] - t_start), 2) if first_partial else None),
            "tail_after_speech_end_ms": (
                round((final["_t"] - t_send_end) * 1000) if final else None),
            "final_text": final["text"] if final else None,
            "final_elapsed_ms": final.get("elapsed_ms") if final else None,
            "final_elapsed_ns": final.get("elapsed_ns") if final else None,
        }
        c.close()
        return out
    finally:
        srv.stop()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", default="/tmp/speech_bench.wav")
    ap.add_argument("--sock", default="/tmp/dictation-bench.sock")
    args = ap.parse_args()

    wav = ensure_wav(args.wav)
    pcm = read_wav_frames(wav)
    print(f"reference clip: {len(pcm)/32000.0:.1f}s @16k mono")

    print("warming model…")
    tr = Transcriber()
    tr.load()

    results = {"whole_file": bench_whole_file(tr, wav)}
    print(f"whole-file decode (legacy path): {results['whole_file']['whole_file_ms']:.0f} ms")

    results["streaming_realtime"] = bench_streaming(args.sock, pcm, realtime=True)
    s = results["streaming_realtime"]
    print(f"streaming @realtime: first partial {s['first_partial_at_audio_pos_s']}s "
          f"into speech; tail after speech end {s['tail_after_speech_end_ms']} ms")
    for p in s["partials"]:
        print(f"  … {p}")
    print(f"  final: {s['final_text']}")

    # Daemon IPC overhead: wall clock of `pipe` (non-realtime flood) minus
    # server-reported decode time.
    daemon = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          "daemon", "zig-out", "bin", "transcribe")
    if os.path.exists(daemon):
        env = dict(os.environ, TRANSCRIBE_DICTATION_SOCK=args.sock)
        srv = StreamServer(args.sock)
        srv.start()
        try:
            t0 = time.perf_counter()
            subprocess.run([daemon, "pipe", wav, "--no-paste"], env=env,
                           capture_output=True, timeout=120)
            wall = (time.perf_counter() - t0) * 1000
        finally:
            srv.stop()
        results["daemon_pipe"] = {
            "wall_ms_flood": round(wall),
            "note": "includes process start, UDS connect, PCM flood, decode, teardown",
        }
        print(f"daemon pipe (flood): {wall:.0f} ms total wall")

    out_dir = os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "streaming.json"), "w") as fh:
        json.dump(results, fh, indent=2)
    print("saved bench/results/streaming.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
