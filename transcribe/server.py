"""Localhost transcription server used by the native menu-bar app.

Serves the warm Whisper model over HTTP on 127.0.0.1 so the Swift app can
transcribe without paying model-load latency per utterance. The server also
owns session storage and TTL cleanup.

Endpoints:
- GET  /health      {"status": "ok", "model": ..., "warm": ...,
                     "lanes": {"primary": true, "overflow": bool}}
- GET  /reload      re-read config and rebuild the warm engine
- POST /transcribe  {"path": "/abs/path.wav", "preserve_source": false,
                     "kind": "dictation" | "file"}   (kind optional)
                    -> {"text": ..., "language": ..., "elapsed": ...}

Two lanes, steady state one: the primary lane serves everything by default.
Only when a dictation arrives while the primary lane is busy does a second
overflow lane appear (its own transcriber, worker thread, and lock) so a
minutes-long file job never blocks a quick utterance. File jobs keep today's
immediate 503 when busy. The overflow lane is evicted after idling so memory
returns to the single-model steady state.
"""

from __future__ import annotations

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import CancelledError
from concurrent.futures import TimeoutError as FuturesTimeoutError
from urllib.parse import urlparse

from transcribe.config import load
from transcribe.engine import Transcriber
from transcribe.storage import clean, save_result, write_transcript_markdown


# Server-side cap on one transcription request. The Swift client has no
# per-request timeout of its own, so a hung engine call would otherwise pin
# the app forever. Generous by design - legitimate jobs are minutes at most;
# tests monkeypatch this to something small. Applied per lane.
REQUEST_TIMEOUT_S = 1800.0

# A long-lived MLX session slowly degrades output quality: after dozens of
# jobs in one process, chunked decodes can hallucinate language tokens
# (observed as stray CJK / "<|ko|>" leaks on long files). Rebuilding the warm
# model between requests bounds that. Cheap by design: a warm reload is a
# fraction of a second of idle time, invisible to the next dictation.
# Counted per lane.
RELOAD_EVERY_N = 40

# An overflow lane exists only to absorb dictation during long jobs. After
# this much idle time it is torn down (checked from the periodic cleanup
# loop), restoring single-model steady-state memory.
OVERFLOW_IDLE_S = 600.0

BUSY_MESSAGE = "engine busy — a transcription is already running"


class _Lane:
    """One warm-engine lane: its own transcriber, worker thread, and lock.

    MLX's GPU stream is thread-local, so every lane pins warm-up and
    inference to its own single-thread executor instead of letting
    ThreadingHTTPServer move work between worker threads.
    """

    def __init__(self, name: str):
        self.name = name
        self.transcriber = Transcriber()
        self.executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix=f"transcribe-engine-{name}")
        self.lock = threading.Lock()
        self.jobs_since_load = 0
        self.served = 0
        self.last_used = time.monotonic()
        self._recycle_gate = threading.Lock()

    def run(self, operation):
        """Run model work on this lane's single engine thread."""
        return self.executor.submit(operation).result()

    def touch(self) -> None:
        self.last_used = time.monotonic()

    def note_job_done(self) -> bool:
        """Count a finished transcription; True when a model refresh is due."""
        self.served += 1
        self.jobs_since_load += 1
        return self.jobs_since_load >= RELOAD_EVERY_N

    def recycle_if_due(self) -> None:
        """Rebuild this lane's warm model in the background (never blocks).

        Skips politely when the lane is mid-job; the counter stays due, so
        the next completed request retries. The gate prevents stacked reloads.
        """
        if not self._recycle_gate.acquire(blocking=False):
            return

        def _work():
            try:
                if self.lock.acquire(blocking=False):
                    try:
                        self.run(self.transcriber.load)
                        self.jobs_since_load = 0
                        print(f"[server] recycled {self.name} model after "
                              f"{RELOAD_EVERY_N} transcriptions", flush=True)
                    finally:
                        self.lock.release()
            finally:
                self._recycle_gate.release()

        threading.Thread(target=_work, name=f"transcribe-recycle-{self.name}",
                         daemon=True).start()

    def abandon_thread(self) -> None:
        """Replace this lane's worker after a timed-out request.

        The stuck call itself cannot be killed; shutting the old executor
        down without waiting leaves its thread running until the underlying
        work returns, while the fresh executor serves subsequent requests
        immediately instead of queueing behind the corpse.
        """
        old = self.executor
        self.executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix=f"transcribe-engine-{self.name}")
        old.shutdown(wait=False, cancel_futures=True)


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
        # A reload rebuilds the warm engine, which can take a while. When a
        # transcription holds the primary lane's lock, answer immediately
        # with a retryable 503 instead of queueing behind a minutes-long job.
        if not self.server.primary.lock.acquire(blocking=False):
            self._send(503, {"error": BUSY_MESSAGE})
            return
        try:
            self.server.run_engine(lambda: self.server.transcriber.load())
            self._send(200, {"status": "reloaded",
                             "model": self.server.transcriber.model})
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"error": f"model load failed: {exc}"})
        finally:
            self.server.primary.lock.release()

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            self._send(200, {
                "status": "ok",
                "model": self.server.transcriber.model,
                "warm": self.server.transcriber.is_warm,
                # Additive lane visibility: overflow is True only between the
                # first busy-time dictation and idle eviction.
                "lanes": {"primary": True,
                          "overflow": self.server._overflow is not None},
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
            kind = body.get("kind")
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(400, {"error": f"bad request: {exc}"})
            return
        if kind is not None and kind not in ("dictation", "file"):
            self._send(400, {"error": f"bad kind: {kind}"})
            return
        if kind is None:
            # Current app behavior: live recordings post preserve_source
            # false, file jobs true. Absent kind infers from that.
            kind = "file" if preserve_source else "dictation"
        if not audio_path or not os.path.exists(audio_path):
            self._send(400, {"error": f"audio file not found: {audio_path}"})
            return

        # Route to a lane. Default is the primary lane - identical behavior
        # to a single-model server whenever no overlap occurs. A dictation
        # that collides with a running job spills to the overflow lane;
        # anything else fails fast instead of hanging the client for minutes.
        lane, busy_reason = self.server.acquire_lane(kind)
        if lane is None:
            self._send(503, {"error": busy_reason})
            return
        try:
            try:
                # The request is capped by REQUEST_TIMEOUT_S so a hung engine
                # call cannot pin the requesting client forever.
                future = lane.executor.submit(
                    lambda: lane.transcriber.transcribe(audio_path))
                result = future.result(timeout=REQUEST_TIMEOUT_S)
            except FuturesTimeoutError:
                # Honest limitation: Python cannot kill a thread. The worker
                # keeps executing the stuck transcription until the underlying
                # call returns on its own; it cannot be reclaimed here. What we
                # can do is stop it from blocking everyone else: swap in a
                # fresh single-worker executor so later requests proceed, and
                # let the abandoned thread finish whenever it finally does (if
                # it truly never returns, its thread delays interpreter exit,
                # because workers are joined at shutdown). Done per lane, so
                # one stuck call only costs its own lane.
                lane.abandon_thread()
                print(f"[server] {lane.name} transcription timed out after "
                      f"{REQUEST_TIMEOUT_S}s: {audio_path}", flush=True)
                self._send(500, {"error": f"transcription timed out after "
                                          f"{REQUEST_TIMEOUT_S}s"})
                return
            except Exception as exc:  # noqa: BLE001 - report any engine failure
                self._send(500, {"error": str(exc)})
                return
        finally:
            lane.lock.release()
            lane.touch()

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

        # Bound long-session quality drift per lane: once enough jobs have
        # run on a lane's process-resident model, quietly rebuild it before
        # more pile up.
        if lane.note_job_done():
            lane.recycle_if_due()


class TranscribeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr: tuple[str, int], verbose: bool = False):
        # Create the primary lane (and its executor) before binding the
        # socket. If another server is already using the port,
        # ThreadingHTTPServer calls server_close() from its failed
        # constructor path and the executor must still be present.
        self.primary = _Lane("primary")
        self._overflow = None
        self._overflow_gate = threading.Lock()
        self.overflow_idle_s = float(OVERFLOW_IDLE_S)
        super().__init__(addr, _Handler)
        self.config = load()
        self.verbose = verbose
        clean(live_ttl_hours=self.config.live_cleanup_ttl_hours,
              file_ttl_hours=self.config.cleanup_ttl_hours)

    # --- stable single-lane surface ---------------------------------------
    # Historical attribute names keep working and always mean the primary
    # lane, which is the only lane in the no-overlap steady state.
    @property
    def lock(self) -> threading.Lock:
        return self.primary.lock

    @property
    def inference_executor(self) -> ThreadPoolExecutor:
        return self.primary.executor

    @property
    def transcriber(self) -> Transcriber:
        return self.primary.transcriber

    @transcriber.setter
    def transcriber(self, value: Transcriber) -> None:
        self.primary.transcriber = value

    @property
    def _jobs_since_load(self) -> int:
        return self.primary.jobs_since_load

    @_jobs_since_load.setter
    def _jobs_since_load(self, value: int) -> None:
        self.primary.jobs_since_load = value

    def note_job_done_and_check_recycle(self) -> bool:
        """Count a finished primary-lane transcription; True when due."""
        return self.primary.note_job_done()

    def recycle_if_due(self) -> None:
        """Rebuild the primary lane's warm model in the background."""
        self.primary.recycle_if_due()

    def run_engine(self, operation):
        """Run primary-lane model work on the thread that warms it."""
        return self.primary.run(operation)

    def abandon_inference_thread(self) -> None:
        """Replace the primary lane's worker after a timed-out request."""
        self.primary.abandon_thread()

    # --- two-lane plumbing -------------------------------------------------
    def acquire_lane(self, kind: str) -> tuple[_Lane | None, str]:
        """Lock a lane for one request of kind "dictation" or "file".

        Returns ``(lane, "")`` with the lane lock held, or ``(None, reason)``
        when nothing is free and the caller must answer 503. File jobs never
        spill: they keep the immediate busy-503. Dictation may lazily create
        the overflow lane; creation and locking happen under one gate, so an
        eviction can never race a request into a dead executor.
        """
        if self.primary.lock.acquire(blocking=False):
            return self.primary, ""
        if kind != "dictation":
            return None, BUSY_MESSAGE
        with self._overflow_gate:
            lane = self._overflow
            if lane is None:
                lane = self._start_overflow()
            if lane.lock.acquire(blocking=False):
                lane.touch()
                return lane, ""
        return None, BUSY_MESSAGE

    def _start_overflow(self) -> _Lane:
        """Create the overflow lane; caller holds ``_overflow_gate``."""
        lane = _Lane("overflow")
        self._overflow = lane
        print("[server] overflow lane created: dictation arrived while the "
              "primary lane was busy", flush=True)

        def _warm():
            try:
                # Warm on the lane's own executor thread; the first
                # overlapped utterance queues behind it (~0.4 s) and later
                # ones find the weights resident.
                lane.run(lane.transcriber.warm)
                print(f"[server] overflow lane warm: "
                      f"{lane.transcriber.model}", flush=True)
            except (Exception, CancelledError) as exc:  # noqa: BLE001
                print(f"[server] overflow lane warm failed: {exc}", flush=True)

        threading.Thread(target=_warm, name="transcribe-overflow-warm",
                         daemon=True).start()
        return lane

    def evict_idle_overflow(self) -> bool:
        """Drop the overflow lane once it has idled past the threshold.

        Called from the periodic cleanup loop. A lane mid-job (lock held) is
        left alone; the next sweep retries. Returns True when a lane was
        evicted.
        """
        with self._overflow_gate:
            lane = self._overflow
            if lane is None:
                return False
            if time.monotonic() - lane.last_used < self.overflow_idle_s:
                return False
            if not lane.lock.acquire(blocking=False):
                return False  # a request is executing on it right now
            self._overflow = None
        # Outside the gate: no new request can reach this lane anymore.
        idle_s = int(time.monotonic() - lane.last_used)
        lane.executor.shutdown(wait=False, cancel_futures=True)
        lane.lock.release()
        print(f"[server] overflow lane evicted after {idle_s}s idle "
              f"({lane.served} transcriptions served)", flush=True)
        return True

    def server_close(self):
        lanes = [self.primary]
        if getattr(self, "_overflow", None) is not None:
            lanes.append(self._overflow)
        for lane in lanes:
            lane.executor.shutdown(wait=True, cancel_futures=True)
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
    # never interferes with an in-flight dictation. The same sweep evicts an
    # overflow lane that has idled out.
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
                try:
                    server.evict_idle_overflow()
                except Exception:
                    pass  # ditto
        threading.Thread(target=_cleanup_loop, name="transcribe-cleanup",
                         daemon=True).start()

    print(f"[server] listening on http://127.0.0.1:{port} — Ctrl-C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
