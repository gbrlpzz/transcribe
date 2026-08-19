"""Localhost transcription server used by the native menu-bar app.

Serves the warm Whisper model over HTTP on 127.0.0.1 so the Swift app can
transcribe without paying model-load latency per utterance. The server also
owns session storage and TTL cleanup.

Endpoints:
- GET  /health                  {"status": "ok", "model": ..., "backend": ...}
- POST /transcribe              {"path": "/abs/path.wav", "language": "auto"}
                                -> {"text": ..., "language": ..., "duration": ...}
"""

from __future__ import annotations

import argparse
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from transcribe.config import Config, load
from transcribe.engine import Transcriber
from transcribe.storage import clean, save_session


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

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            self._send(200, {
                "status": "ok",
                "model": self.server.transcriber.model,
                "backend": self.server.transcriber.backend,
                "warm": self.server.transcriber.is_warm,
            })
        elif path == "/reload":
            # re-read config and reload the model (used by the app when the model changes)
            with self.server.lock:
                cfg = load()
                self.server.transcriber = Transcriber(
                    model=cfg.model, backend=cfg.backend, language=cfg.language)
                try:
                    self.server.transcriber.load()
                    self._send(200, {"status": "reloaded",
                                     "model": self.server.transcriber.model,
                                     "backend": self.server.transcriber.backend})
                except Exception as exc:  # noqa: BLE001
                    self._send(500, {"error": f"model load failed: {exc}"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        parsed_path = urlparse(self.path).path
        if parsed_path == "/reload":
            with self.server.lock:
                cfg = load()
                self.server.transcriber = Transcriber(
                    model=cfg.model, backend=cfg.backend, language=cfg.language)
                try:
                    self.server.transcriber.load()
                    self._send(200, {"status": "reloaded",
                                     "model": self.server.transcriber.model,
                                     "backend": self.server.transcriber.backend})
                except Exception as exc:  # noqa: BLE001
                    self._send(500, {"error": f"model load failed: {exc}"})
            return
        if parsed_path != "/transcribe":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            audio_path = body.get("path", "")
            language = body.get("language", "auto")
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(400, {"error": f"bad request: {exc}"})
            return
        if not audio_path or not os.path.exists(audio_path):
            self._send(400, {"error": f"audio file not found: {audio_path}"})
            return

        with self.server.lock:
            try:
                result = self.server.transcriber.transcribe(audio_path, language=language)
            except Exception as exc:  # noqa: BLE001 - report any engine failure
                self._send(500, {"error": str(exc)})
                return

        # store a copy + transcript (TTL cleanup handles bloat)
        duration = result.get("duration", 0.0)
        try:
            save_session(
                audio_path, result["text"], duration=duration,
                model=result["model"], language=result.get("language", ""),
                source="app", keep_transcripts=self.server.config.keep_transcripts,
            )
        except OSError:
            pass  # never fail a transcription because of bookkeeping

        self._send(200, {
            "text": result["text"],
            "language": result.get("language", ""),
            "model": result["model"],
            "backend": result["backend"],
            "elapsed": result.get("elapsed", 0.0),
        })


class TranscribeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr: tuple[str, int], config: Config, verbose: bool = False):
        super().__init__(addr, _Handler)
        self.config = config
        self.verbose = verbose
        self.lock = threading.Lock()
        self.transcriber = Transcriber(model=config.model, backend=config.backend,
                                       language=config.language)
        clean(config.cleanup_ttl_hours)


def serve(port: int | None = None, *, warm: bool | None = None, verbose: bool = False) -> None:
    """Run the server (blocking)."""
    config = load()
    port = port or config.port
    if warm is None:
        warm = config.warm_on_start
    server = TranscribeServer(("127.0.0.1", port), config, verbose=verbose)
    if warm:
        def _warm():
            try:
                # Serialize warm-up with requests. A health check can succeed
                # while weights are loading, but the first transcription must
                # never race a second model initialization.
                with server.lock:
                    server.transcriber.warm()
                print(f"[server] model loaded: {server.transcriber.model} "
                      f"({server.transcriber.backend})", flush=True)
            except Exception as exc:
                print(f"[server] model load failed: {exc}", flush=True)
        threading.Thread(target=_warm, daemon=True).start()
    print(f"[server] listening on http://127.0.0.1:{port} — Ctrl-C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
