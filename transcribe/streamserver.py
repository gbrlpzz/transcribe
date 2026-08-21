"""Streaming dictation endpoint for the warm engine.

The Zig capture daemon (``daemon/``) streams raw PCM over a Unix socket; this
module turns the stream into text while the user is still speaking.

Protocol v1 (fixed contract with the daemon):

- Transport: Unix domain socket at ``<home>/dictation.sock`` (override with
  ``TRANSCRIBE_DICTATION_SOCK``).
- Framing: every message is a little-endian ``u32`` length prefix followed by
  that many payload bytes.
- A payload starting with ``{`` is a JSON control message; anything else is
  raw PCM (s16le, mono, 16 kHz).
- Client -> server control: ``{"op": "start", "language": "auto",
  "session": "<id>"}``, then PCM frames (~100 ms each), then
  ``{"op": "stop"}``.
- Server -> client events: ``{"ev": "ready"}`` after start,
  ``{"ev": "partial", "text": ...}`` after each chunk decode,
  ``{"ev": "final", "text": ..., "elapsed_ms": ...}`` after stop, and
  ``{"ev": "error", "msg": ...}`` on failure.

Audio pipeline: an energy VAD gates silence out, speech is buffered and
decoded in overlapping chunks (>=1.5 s of speech plus a >=320 ms pause, or a
4 s hard cap), and repeated words at chunk seams are deduped. The model stays
warm across decodes via a shared :class:`transcribe.engine.Transcriber`.

Run with ``python -m transcribe.streamserver`` (add ``--selftest`` for a
loopback test with a mocked transcriber).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import socket
import struct
import sys
import tempfile
import threading
import time
from typing import Any, Callable

from transcribe.config import default_home

# --- protocol helpers -------------------------------------------------------

def send_msg(sock: socket.socket, payload: bytes) -> None:
    """Write one length-prefixed message."""
    sock.sendall(struct.pack("<I", len(payload)) + payload)


def send_event(sock: socket.socket, event: dict[str, Any]) -> None:
    send_msg(sock, json.dumps(event).encode("utf-8"))


def recv_exact(sock: socket.socket, n: int) -> bytes | None:
    """Read exactly ``n`` bytes; ``None`` on clean EOF at a message boundary."""
    buf = bytearray()
    while len(buf) < n:
        try:
            chunk = sock.recv(n - len(buf))
        except (ConnectionResetError, OSError):
            return None
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def recv_msg(sock: socket.socket) -> bytes | None:
    header = recv_exact(sock, 4)
    if header is None:
        return None
    (length,) = struct.unpack("<I", header)
    if length == 0 or length > 32 * 1024 * 1024:
        raise ValueError(f"bad frame length {length}")
    body = recv_exact(sock, length)
    if body is None:
        raise ValueError("truncated frame")
    return body


def default_sock_path() -> str:
    override = os.environ.get("TRANSCRIBE_DICTATION_SOCK")
    if override:
        return override
    return os.path.join(default_home(), "dictation.sock")


# --- voice activity detection ------------------------------------------------

class EnergyVAD:
    """Energy-based VAD with adaptive noise floor and hangover.

    Operates on 20 ms frames of mono s16le PCM at 16 kHz. A pluggable
    replacement (e.g. Silero ONNX) only needs to implement ``feed()``.
    """

    FRAME_MS = 20
    BYTES_PER_FRAME = 320 * 2  # 320 samples * 2 bytes

    def __init__(self, *, threshold_db: float = -45.0, margin_db: float = 10.0,
                 hangover_ms: int = 300):
        self.threshold_db = threshold_db
        self.margin_db = margin_db
        self.hangover_frames = max(1, hangover_ms // self.FRAME_MS)
        self.noise_floor_db = -70.0
        self.speech = False
        self._quiet_run = 0

    def feed(self, pcm: bytes) -> bool:
        """Consume arbitrary-length PCM; returns True while speech continues."""
        for i in range(0, len(pcm) - len(pcm) % self.BYTES_PER_FRAME,
                       self.BYTES_PER_FRAME):
            frame = pcm[i:i + self.BYTES_PER_FRAME]
            self._feed_frame(frame)
        return self.speech

    def _feed_frame(self, frame: bytes) -> None:
        samples = struct.unpack(f"<{len(frame) // 2}h", frame)
        rms = (sum(s * s for s in samples) / len(samples)) ** 0.5
        db = 20.0 * math.log10(max(rms, 1e-9) / 32768.0)
        # Adapt the noise floor down during quiet stretches only.
        if db < self.noise_floor_db + 6.0:
            self.noise_floor_db = 0.98 * self.noise_floor_db + 0.02 * db
        open_at = max(self.noise_floor_db + self.margin_db, self.threshold_db)
        if db > open_at:
            self.speech = True
            self._quiet_run = 0
        elif self.speech:
            self._quiet_run += 1
            if self._quiet_run >= self.hangover_frames:
                self.speech = False
                self._quiet_run = 0


# --- chunked dictation session ----------------------------------------------

PRE_ROLL_MS = 120          # captured before speech onset
CHUNK_MIN_SPEECH_MS = 1500  # decode once this much speech is buffered...
CHUNK_PAUSE_MS = 320       # ...after this much trailing pause
CHUNK_HARD_CAP_MS = 4000   # ...or immediately at this much buffered audio
SEAM_WORDS = 8             # context window for seam dedupe


def dedupe_seam(prev_text: str, new_text: str, max_words: int = SEAM_WORDS) -> str:
    """Strip words repeated across a chunk boundary.

    Whisper re-decodes overlap regions, so a chunk often re-emits the last few
    words of the previous one. Drop the longest suffix/prefix word match.
    """
    prev_words = prev_text.split()
    new_words = new_text.split()
    limit = min(max_words, len(prev_words), len(new_words))
    for k in range(limit, 0, -1):
        if [w.lower().strip(".,!?;:") for w in prev_words[-k:]] == \
           [w.lower().strip(".,!?;:") for w in new_words[:k]]:
            return " ".join(new_words[k:])
    return new_text


class DictationSession:
    """Buffers gated speech for one utterance and emits chunk decodes."""

    def __init__(self, session_id: str, language: str,
                 transcribe_fn: Callable[[str, str], str]):
        self.session_id = session_id
        self.language = language or "auto"
        self._transcribe = transcribe_fn
        self.vad = EnergyVAD()
        self.pre_roll = bytearray()
        self.buffer = bytearray()
        self.trailing_silence_frames = 0
        self.speech_ms = 0
        self.seen_any_speech = False
        self.text_parts: list[str] = []
        self.started = time.time()

    def feed(self, pcm: bytes) -> list[str]:
        """Consume PCM; returns partial texts to emit (may be empty)."""
        partials: list[str] = []
        step = EnergyVAD.BYTES_PER_FRAME
        for i in range(0, len(pcm) - len(pcm) % step, step):
            frame = pcm[i:i + step]
            was_speech = self.vad.speech
            is_speech = self.vad.feed(frame)
            if not self.seen_any_speech:
                self.pre_roll.extend(frame)
                if len(self.pre_roll) > PRE_ROLL_MS * 16:  # 16 bytes/ms
                    del self.pre_roll[:-PRE_ROLL_MS * 16]
                if is_speech:
                    self.seen_any_speech = True
                    self.buffer += self.pre_roll
                    self.speech_ms += len(self.buffer) // 32
                    self.pre_roll.clear()
            elif is_speech or was_speech:
                self.buffer.extend(frame)
                if is_speech:
                    self.speech_ms += EnergyVAD.FRAME_MS
                    self.trailing_silence_frames = 0
                else:
                    self.trailing_silence_frames += 1
            if (self.seen_any_speech and self.speech_ms >= CHUNK_MIN_SPEECH_MS
                    and self.trailing_silence_frames * EnergyVAD.FRAME_MS
                    >= CHUNK_PAUSE_MS):
                partials.extend(self._decode())
            elif self._buffered_ms() >= CHUNK_HARD_CAP_MS:
                partials.extend(self._decode())
        return partials

    def stop(self) -> tuple[str, float]:
        """Finalize; returns (full text, elapsed ms, trailing partials)."""
        final_partials = self._decode(force=True)
        elapsed = (time.time() - self.started) * 1000.0
        return " ".join(self.text_parts).strip(), elapsed, final_partials

    def _buffered_ms(self) -> float:
        return len(self.buffer) / 32.0  # 16 kHz * 2 bytes = 32 bytes/ms

    def _decode(self, force: bool = False) -> list[str]:
        if not self.buffer:
            return []
        audio_ms = self._buffered_ms()
        if audio_ms < 300 and not force:
            return []  # too little audio to be worth a decode
        wav_path = _write_temp_wav(bytes(self.buffer))
        try:
            text = self._transcribe(wav_path, self.language).strip()
        finally:
            try:
                os.remove(wav_path)
            except OSError:
                pass
        # Keep ~200 ms of tail as decoding overlap context for seam dedupe.
        overlap_bytes = min(len(self.buffer), 200 * 32)
        tail = bytes(self.buffer[-overlap_bytes:])
        self.buffer.clear()
        self.speech_ms = 0
        self.trailing_silence_frames = 0
        if not text:
            return []
        prev = " ".join(self.text_parts)
        addition = dedupe_seam(prev, text) if prev else text
        if addition:
            self.text_parts.append(addition)
            return [addition]
        return []


def _write_temp_wav(pcm: bytes, sample_rate: int = 16000) -> str:
    fd, path = tempfile.mkstemp(suffix=".wav")
    with os.fdopen(fd, "wb") as fh:
        import struct as _struct
        header = _struct.pack(
            "<4sI4s4sIHHIIHH4sI",
            b"RIFF", 36 + len(pcm), b"WAVE",
            b"fmt ", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16,
            b"data", len(pcm),
        )
        fh.write(header)
        fh.write(pcm)
    return path


# --- server -------------------------------------------------------------------

_transcriber = None
_transcriber_lock = threading.Lock()


def _get_transcriber():
    """Lazy shared Transcriber so the model stays warm across sessions."""
    global _transcriber
    with _transcriber_lock:
        if _transcriber is None:
            from transcribe.engine import Transcriber
            _transcriber = Transcriber()
        return _transcriber


def _default_transcribe(wav_path: str, language: str) -> str:
    result = _get_transcriber().transcribe(
        wav_path, language=None if language == "auto" else language)
    return result.get("text", "")


class StreamServer:
    """Single-client Unix-socket streaming server."""

    def __init__(self, sock_path: str | None = None,
                 transcribe_fn: Callable[[str, str], str] | None = None):
        self.sock_path = sock_path or default_sock_path()
        self.transcribe_fn = transcribe_fn or _default_transcribe
        self._server_sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    def start(self) -> None:
        os.makedirs(os.path.dirname(self.sock_path), exist_ok=True)
        try:
            os.remove(self.sock_path)
        except OSError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock_path)
        srv.listen(1)
        self._server_sock = srv
        self._thread = threading.Thread(target=self._serve, daemon=True,
                                        name="streamserver")
        self._thread.start()

    def wait_ready(self, timeout: float = 5.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(self.sock_path):
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    client.connect(self.sock_path)
                    client.close()
                    return True
                except OSError:
                    pass
            time.sleep(0.02)
        return False

    def stop(self) -> None:
        self._stop.set()
        if self._server_sock:
            try:
                self._server_sock.close()
            except OSError:
                pass
        try:
            os.remove(self.sock_path)
        except OSError:
            pass

    def _serve(self) -> None:
        srv = self._server_sock
        assert srv is not None
        srv.settimeout(0.5)
        while not self._stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                self._handle(conn)
            except Exception as exc:  # noqa: BLE001 - report to client
                try:
                    send_event(conn, {"ev": "error", "msg": str(exc)})
                except OSError:
                    pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def _handle(self, conn: socket.socket) -> None:
        conn.settimeout(None)
        session: DictationSession | None = None
        while True:
            try:
                payload = recv_msg(conn)
            except ValueError as exc:
                send_event(conn, {"ev": "error", "msg": str(exc)})
                return
            if payload is None:
                return
            if payload.startswith(b"{"):
                msg = json.loads(payload.decode("utf-8"))
                op = msg.get("op")
                if op == "start":
                    session = DictationSession(
                        msg.get("session", ""), msg.get("language", "auto"),
                        self.transcribe_fn)
                    send_event(conn, {"ev": "ready"})
                elif op == "stop":
                    if session is None:
                        send_event(conn, {"ev": "error", "msg": "stop before start"})
                        return
                    text, elapsed, extra = session.stop()
                    for part in extra:
                        send_event(conn, {"ev": "partial", "text": part})
                    send_event(conn, {"ev": "final", "text": text,
                                      "elapsed_ms": round(elapsed)})
                    session = None
                elif op == "cancel":
                    session = None
                    send_event(conn, {"ev": "ready"})
                else:
                    send_event(conn, {"ev": "error", "msg": f"unknown op {op!r}"})
            else:
                if session is None:
                    send_event(conn, {"ev": "error",
                                      "msg": "pcm before start"})
                    return
                for part in session.feed(payload):
                    send_event(conn, {"ev": "partial", "text": part})


# --- CLI ----------------------------------------------------------------------

def _selftest(sock_path: str) -> int:
    """Loopback test with a mocked transcriber; exits 0 on success."""
    calls = {"n": 0}

    def fake_transcribe(path: str, language: str) -> str:
        calls["n"] += 1
        seconds = os.path.getsize(path) / 32000.0
        return f"chunk{calls['n']}({seconds:.1f}s)"

    srv = StreamServer(sock_path, transcribe_fn=fake_transcribe)
    srv.start()
    assert srv.wait_ready(), "server did not become ready"

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(sock_path)
    send_msg(client, json.dumps({"op": "start", "language": "auto",
                                 "session": "selftest"}).encode())

    def read_events(timeout=10.0):
        client.settimeout(timeout)
        events = []
        while True:
            head = recv_exact(client, 4)
            assert head is not None, "eof waiting for events"
            (n,) = struct.unpack("<I", head)
            body = recv_exact(client, n)
            ev = json.loads(body.decode())
            events.append(ev)
            if ev.get("ev") in ("final", "error"):
                return events

    # 2.2 s of loud "speech" then 0.5 s silence triggers one chunk decode.
    speech_frame = struct.pack("<h", 9000) * 320
    silence_frame = b"\x00" * 640
    stream = bytearray()
    stream += speech_frame * 110   # 2.2 s
    stream += silence_frame * 25   # 0.5 s
    for i in range(0, len(stream), 3200):
        send_msg(client, bytes(stream[i:i + 3200]))
    send_msg(client, json.dumps({"op": "stop"}).encode())
    events = read_events()

    kinds = [e["ev"] for e in events]
    assert kinds[0] == "ready", kinds
    assert "partial" in kinds, f"no partials: {kinds}"
    final = events[-1]
    assert final["ev"] == "final" and final["text"], final
    print(f"selftest OK: events={kinds} final={final['text']!r} "
          f"elapsed_ms={final['elapsed_ms']}")
    client.close()
    srv.stop()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="transcribe.streamserver",
                                     description="Streaming dictation engine")
    parser.add_argument("--sock", default=None, help="unix socket path")
    parser.add_argument("--selftest", action="store_true",
                        help="run loopback test with mocked transcriber")
    args = parser.parse_args(argv)

    sock_path = args.sock or default_sock_path()
    if args.selftest:
        return _selftest(sock_path)

    from transcribe.engine import available_backends
    backends = available_backends()
    if not backends:
        print("error: no transcription backend installed "
              "(pip install 'transcribe[mlx]' on Apple Silicon)", file=sys.stderr)
        return 1

    srv = StreamServer(sock_path)
    srv.start()
    print(f"stream server listening on {sock_path} "
          f"(backend={backends[0]}, model warm on first use)")
    try:
        threading.Event().wait()  # sleep forever
    except KeyboardInterrupt:
        pass
    finally:
        srv.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
