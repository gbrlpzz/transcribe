"""Tests for the streaming dictation server (protocol v1)."""

import json
import socket
import struct

import pytest

from transcribe import streamserver as ss


# --- framing -----------------------------------------------------------------

def test_send_recv_roundtrip(tmp_path):
    import threading
    a, b = socket.socketpair()
    ss.send_msg(a, b"hello")
    ss.send_event(a, {"ev": "ready"})
    assert ss.recv_msg(b) == b"hello"
    header = ss.recv_exact(b, 4)
    (n,) = struct.unpack("<I", header)
    assert json.loads(ss.recv_exact(b, n)) == {"ev": "ready"}
    a.close()
    b.close()


def test_recv_msg_rejects_bad_length():
    a, b = socket.socketpair()
    b.sendall(struct.pack("<I", 99999999))
    with pytest.raises(ValueError):
        ss.recv_msg(a)
    a.close()
    b.close()


# --- VAD ----------------------------------------------------------------------

def _tone(amplitude=9000, frames=100):
    return (struct.pack("<h", amplitude) * 320) * frames


def test_vad_silence_stays_silent():
    vad = ss.EnergyVAD()
    assert not vad.feed(b"\x00" * 640 * 50)


def test_vad_detects_tone_and_hangs_over():
    vad = ss.EnergyVAD()
    vad.feed(_tone(frames=10))
    assert vad.speech
    # hangover: speech stays True for ~300 ms of silence after the tone
    for _ in range(10):
        vad.feed(b"\x00" * 640)
        assert vad.speech
    for _ in range(10):
        vad.feed(b"\x00" * 640)
    assert not vad.speech


def test_vad_adapts_to_noise_floor():
    vad = ss.EnergyVAD(threshold_db=-40.0)
    quiet = (struct.pack("<h", 60) * 320) * 200  # low-level hum
    vad.feed(quiet)
    assert not vad.speech


# --- seam dedupe --------------------------------------------------------------

def test_dedupe_seam_strips_overlap():
    assert ss.dedupe_seam("hello world how are", "are you today") == "you today"


def test_dedupe_seam_case_and_punctuation_insensitive():
    assert ss.dedupe_seam("the end.", "The end! Of it") == "Of it"


def test_dedupe_seam_no_overlap_keeps_all():
    assert ss.dedupe_seam("alpha beta", "gamma delta") == "gamma delta"


# --- session chunking -----------------------------------------------------------

def test_format_elapsed_ns_preserves_sub_millisecond_units():
    assert ss.format_elapsed_ns(0) == "unmeasured"
    assert ss.format_elapsed_ns(42) == "42 ns"
    assert ss.format_elapsed_ns(1_234) == "1.234 µs"
    assert ss.format_elapsed_ns(1_234_567) == "1.234567 ms"


def test_session_ignores_silence_only_stream():
    calls = []
    sess = ss.DictationSession("t", "auto",
                               lambda p, l: calls.append(p) or "x")
    out = sess.feed(b"\x00" * 640 * 200)  # 4 s of silence
    text, elapsed, extra = sess.stop()
    assert out == [] and calls == [] and text == ""


def test_session_decodes_short_utterance_on_stop(tmp_path):
    seen = []

    def fake_transcribe(path, language):
        seen.append((path, language))
        return "ciao mondo"

    sess = ss.DictationSession("t", "auto", fake_transcribe)
    partials = sess.feed(_tone(frames=80))          # 1.6 s speech
    partials += sess.feed(b"\x00" * 640 * 30)       # 0.6 s pause -> chunk decode
    text, elapsed, extra = sess.stop()
    assert seen, "expected at least one decode"
    assert "ciao mondo" in text


def test_session_language_passthrough():
    got = {}
    def fake_transcribe(path, language):
        got["language"] = language
        return "ok"
    sess = ss.DictationSession("t", "it", fake_transcribe)
    sess.feed(_tone(frames=80))
    sess.stop()
    assert got["language"] == "it"


# --- end-to-end over a real unix socket -----------------------------------------

@pytest.fixture()
def server():
    # AF_UNIX paths are limited to ~104 chars on macOS; pytest tmp_path is longer.
    import tempfile
    sock = tempfile.mkdtemp(prefix="tsrv.") + "/d.sock"
    srv = ss.StreamServer(sock, transcribe_fn=lambda p, l: f"echo({l or 'auto'})")
    srv.start()
    assert srv.wait_ready()
    yield sock
    srv.stop()


def _client(sock):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.connect(sock)
    return c


def _read_until_final(client):
    client.settimeout(10)
    events = []
    while True:
        head = ss.recv_exact(client, 4)
        assert head is not None
        (n,) = struct.unpack("<I", head)
        events.append(json.loads(ss.recv_exact(client, n)))
        if events[-1]["ev"] in ("final", "error"):
            return events


def test_full_dictation_roundtrip(server):
    c = _client(server)
    ss.send_msg(c, json.dumps({"op": "start", "language": "auto",
                               "session": "r1"}).encode())
    ss.send_msg(c, _tone(frames=80))
    ss.send_msg(c, b"\x00" * 640 * 25)
    ss.send_msg(c, json.dumps({"op": "stop"}).encode())
    events = _read_until_final(c)
    kinds = [e["ev"] for e in events]
    assert kinds[0] == "ready"
    final = events[-1]
    assert final["ev"] == "final" and final["text"] == "echo(auto)"
    assert isinstance(final["elapsed_ms"], int)
    assert isinstance(final["elapsed_ns"], int)
    assert final["elapsed_ns"] > 0
    c.close()


def test_pcm_before_start_is_an_error(server):
    c = _client(server)
    ss.send_msg(c, _tone(frames=2))
    events = _read_until_final(c)
    assert events[-1]["ev"] == "error"
    c.close()


def test_two_sessions_on_one_connection(server):
    c = _client(server)
    for name in ("a", "b"):
        ss.send_msg(c, json.dumps({"op": "start", "session": name}).encode())
        ss.send_msg(c, _tone(frames=80))
        ss.send_msg(c, json.dumps({"op": "stop"}).encode())
        events = _read_until_final(c)
        assert events[-1]["text"].startswith("echo(")
    c.close()


@pytest.mark.skipif(not __import__("os").environ.get("TRANSCRIBE_LIVE_TEST"),
                    reason="live model test; set TRANSCRIBE_LIVE_TEST=1")
def test_live_model_decode(server_factory=None):
    """Real decode through the warm engine (slow; opt-in)."""
    import tempfile, os as _os
    from transcribe.engine import Transcriber
    tr = Transcriber()

    def live(wav, lang):
        return tr.transcribe(wav, language=None if lang == "auto" else lang)["text"]

    sock = _os.path.join(tempfile.mkdtemp(), "live.sock")
    srv = ss.StreamServer(sock, transcribe_fn=live)
    srv.start()
    assert srv.wait_ready()
    c = _client(sock)
    ss.send_msg(c, json.dumps({"op": "start"}).encode())
    ss.send_msg(c, _tone(frames=80))
    ss.send_msg(c, json.dumps({"op": "stop"}).encode())
    events = _read_until_final(c)
    assert events[-1]["ev"] == "final"
    srv.stop()
