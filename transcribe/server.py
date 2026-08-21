"""Localhost transcription server used by the native menu-bar app.

Serves the warm Whisper model over HTTP on 127.0.0.1 so the Swift app can
transcribe without paying model-load latency per utterance. The server also
owns session storage and TTL cleanup.

Endpoints:
- GET  /health                  {"status": "ok", "model": ..., "backend": ...}
- POST /transcribe              {"path": "/abs/path.wav", "language": "auto",
                                 "preserve_source": false}
                                -> {"text": ..., "language": ..., "duration": ...}
"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from concurrent.futures import ThreadPoolExecutor
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
            # re-read configuration and reload the warm model
            with self.server.lock:
                cfg = load()
                try:
                    def reload_model():
                        transcriber = Transcriber(
                            model=cfg.model, backend=cfg.backend, language=cfg.language)
                        transcriber.load()
                        self.server.transcriber = transcriber
                        self.server.config = cfg

                    self.server.run_engine(reload_model)
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
                try:
                    def reload_model():
                        transcriber = Transcriber(
                            model=cfg.model, backend=cfg.backend, language=cfg.language)
                        transcriber.load()
                        self.server.transcriber = transcriber
                        self.server.config = cfg

                    self.server.run_engine(reload_model)
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
            preserve_source = bool(body.get("preserve_source", False))
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(400, {"error": f"bad request: {exc}"})
            return
        if not audio_path or not os.path.exists(audio_path):
            self._send(400, {"error": f"audio file not found: {audio_path}"})
            return

        with self.server.lock:
            try:
                # MLX's GPU stream is thread-local. Keep warm-up and every
                # inference on one dedicated engine thread instead of letting
                # ThreadingHTTPServer move requests between worker threads.
                result = self.server.run_engine(
                    lambda: self.server.transcriber.transcribe(
                        audio_path, language=language))
            except Exception as exc:  # noqa: BLE001 - report any engine failure
                self._send(500, {"error": str(exc)})
                return

        # store a copy + transcript (TTL cleanup handles bloat)
        duration = result.get("duration", 0.0)
        try:
            is_file_job = preserve_source
            save_session(
                None if is_file_job else audio_path,
                result["text"], duration=duration,
                model=result["model"], language=result.get("language", ""),
                source="file" if is_file_job else "live",
                keep_transcripts=self.server.config.keep_transcripts,
                source_path=audio_path if is_file_job else "",
                transcript_path=(os.path.splitext(audio_path)[0] + ".md"
                                 if is_file_job else ""),
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
        # Create the executor before binding the socket. If another server is
        # already using the port, ThreadingHTTPServer calls server_close() from
        # its failed constructor path and the executor must still be present.
        self.inference_executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="transcribe-engine")
        super().__init__(addr, _Handler)
        self.config = config
        self.verbose = verbose
        self.lock = threading.Lock()
        self.transcriber = Transcriber(model=config.model, backend=config.backend,
                                       language=config.language)
        clean(live_ttl_hours=config.live_cleanup_ttl_hours,
              file_ttl_hours=config.cleanup_ttl_hours)

    def run_engine(self, operation):
        """Run model work on the one thread that also performs warm-up."""
        return self.inference_executor.submit(operation).result()

    def server_close(self):
        self.inference_executor.shutdown(wait=True, cancel_futures=True)
        super().server_close()


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
                # Warm-up and requests share one thread because MLX's GPU
                # stream is thread-local. A health check can succeed while
                # weights are loading; requests wait in the same executor.
                server.run_engine(server.transcriber.warm)
                print(f"[server] model loaded: {server.transcriber.model} "
                      f"({server.transcriber.backend})", flush=True)
            except Exception as exc:
                print(f"[server] model load failed: {exc}", flush=True)
        threading.Thread(target=_warm, daemon=True).start()
    # Expired live recordings and file transcripts are removed at startup and
    # then swept periodically, so a long-running engine never accumulates data
    # past the configured TTLs. The sweep touches only expired files, so it
    # never interferes with an in-flight dictation.
    interval_minutes = getattr(config, "cleanup_interval_minutes", 30.0)
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

    # The streaming dictation endpoint shares this process (and the warm
    # model) with the HTTP server; the Zig daemon connects to it.
    stream = None
    try:
        from transcribe.streamserver import StreamServer
        stream = StreamServer()
        stream.start()
        print(f"[server] stream socket: {stream.sock_path}", flush=True)
    except OSError as exc:
        print(f"[server] stream socket unavailable: {exc}", flush=True)

    print(f"[server] listening on http://127.0.0.1:{port} — Ctrl-C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if stream is not None:
            stream.stop()
        server.server_close()
