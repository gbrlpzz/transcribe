"""Localhost transcription server used by the native menu-bar app.

Serves the warm Whisper model over HTTP on 127.0.0.1 so the Swift app can
transcribe without paying model-load latency per utterance. The server also
owns session storage and TTL cleanup.

Endpoints:
- GET  /health      {"status": "ok", "model": ..., "warm": ...}
- GET  /reload      re-read config and rebuild the warm engine
- POST /transcribe  {"path": "/abs/path.wav", "preserve_source": false}
                    -> {"text": ..., "language": ..., "elapsed": ...}
"""

from __future__ import annotations

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse

from transcribe.config import load
from transcribe.engine import Transcriber
from transcribe.storage import clean, save_result, write_transcript_markdown


class _Handler(BaseHTTPRequestHandler):
    server: "TranscribeServer"  # type: ignore[assignment]

    def log_message(self, fmt, *args):  # quiet by default
        if self.server.verbose:
            print("[server]", fmt % args)

    def _send(self, code: int, payload: dict | str):
        body = json.dumps(payload).encode() if not isinstance(payload, str) else payload.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _reload(self):
        with self.server.lock:
            try:
                self.server.run_engine(lambda: self.server.transcriber.load())
                self._send(200, {"status": "reloaded",
                                 "model": self.server.transcriber.model})
            except Exception as exc:  # noqa: BLE001
                self._send(500, {"error": f"model load failed: {exc}"})

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            self._send(200, {
                "status": "ok",
                "model": self.server.transcriber.model,
                "warm": self.server.transcriber.is_warm,
            })
        elif path == "/reload":
            self._reload()
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if urlparse(self.path).path != "/transcribe":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            audio_path = body.get("path", "")
            preserve_source = bool(body.get("preserve_source", False))
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(400, {"error": f"bad request: {exc}"})
            return
        if not audio_path or not os.path.exists(audio_path):
            self._send(400, {"error": f"audio file not found: {audio_path}"})
            return

        # One model, one engine thread. A second request while one is running
        # fails fast with a truthful message instead of hanging the client for
        # minutes behind a long file job.
        if not self.server.lock.acquire(blocking=False):
            self._send(503, {"error": "engine busy — a transcription is already running"})
            return
        try:
            try:
                # MLX's GPU stream is thread-local. Keep warm-up and every
                # inference on one dedicated engine thread instead of letting
                # ThreadingHTTPServer move requests between worker threads.
                result = self.server.run_engine(
                    lambda: self.server.transcriber.transcribe(audio_path))
            except Exception as exc:  # noqa: BLE001 - report any engine failure
                self._send(500, {"error": str(exc)})
                return
        finally:
            self.server.lock.release()

        md_path = ""
        if preserve_source:
            # The engine writes the transcript itself so a finished file job
            # produces its .md even if the requesting app timed out or quit.
            try:
                md_path = write_transcript_markdown(audio_path, result["text"])
            except OSError:
                md_path = ""  # app falls back to writing it

        # store a copy + transcript (TTL cleanup handles bloat)
        save_result(
            result["text"], result,
            None if preserve_source else audio_path,
            source="file" if preserve_source else "live",
            keep_transcripts=self.server.config.keep_transcripts,
            source_path=audio_path if preserve_source else "",
            transcript_path=md_path,
        )

        self._send(200, {
            "text": result["text"],
            "language": result.get("language", ""),
            "model": result["model"],
            "elapsed": result.get("elapsed", 0.0),
            "transcript_path": md_path,
        })


class TranscribeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr: tuple[str, int], verbose: bool = False):
        # Create the executor before binding the socket. If another server is
        # already using the port, ThreadingHTTPServer calls server_close() from
        # its failed constructor path and the executor must still be present.
        self.inference_executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="transcribe-engine")
        super().__init__(addr, _Handler)
        self.config = load()
        self.verbose = verbose
        self.lock = threading.Lock()
        self.transcriber = Transcriber()
        clean(live_ttl_hours=self.config.live_cleanup_ttl_hours,
              file_ttl_hours=self.config.cleanup_ttl_hours)

    def run_engine(self, operation):
        """Run model work on the one thread that also performs warm-up."""
        return self.inference_executor.submit(operation).result()

    def server_close(self):
        self.inference_executor.shutdown(wait=True, cancel_futures=True)
        super().server_close()


def serve(port: int | None = None, *, verbose: bool = False) -> None:
    """Run the server (blocking). The model warms in the background."""
    config = load()
    port = port or config.port
    server = TranscribeServer(("127.0.0.1", port), verbose=verbose)

    def _warm():
        try:
            # Warm-up and requests share one thread because MLX's GPU
            # stream is thread-local. A health check can succeed while
            # weights are loading; requests wait in the same executor.
            server.run_engine(server.transcriber.warm)
            print(f"[server] model loaded: {server.transcriber.model}", flush=True)
        except Exception as exc:
            print(f"[server] model load failed: {exc}", flush=True)
    threading.Thread(target=_warm, daemon=True).start()

    # Expired live recordings and file transcripts are removed at startup and
    # then swept periodically, so a long-running engine never accumulates data
    # past the configured TTLs. The sweep touches only expired files, so it
    # never interferes with an in-flight dictation.
    interval_minutes = config.cleanup_interval_minutes
    if interval_minutes > 0:
        def _cleanup_loop() -> None:
            while True:
                time.sleep(interval_minutes * 60)
                try:
                    clean(live_ttl_hours=config.live_cleanup_ttl_hours,
                          file_ttl_hours=config.cleanup_ttl_hours)
                except OSError:
                    pass  # bookkeeping must never take the engine down
        threading.Thread(target=_cleanup_loop, name="transcribe-cleanup",
                         daemon=True).start()

    print(f"[server] listening on http://127.0.0.1:{port} — Ctrl-C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
