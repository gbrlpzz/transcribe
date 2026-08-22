"""Transcribe command-line interface.

Usage:
    transcribe                  dictate from the microphone (Enter to stop)
    transcribe file AUDIO...    transcribe existing files
    transcribe start|stop|restart   control the background engine
    transcribe serve            run the engine in the foreground
    transcribe clean            remove recordings/transcripts older than TTL
    transcribe config           get/set the few remaining settings
    transcribe doctor           diagnose the setup (ffmpeg, mlx, perms)
    transcribe app              build / install / launch the native app
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import types
import urllib.error
import urllib.request

from transcribe import __version__
from transcribe.audio import record_interactive
from transcribe.config import config_path, load, save
from transcribe.engine import Transcriber, transcribe
from transcribe.paste import check_accessibility, paste_text
from transcribe.smarttext import apply_smart_text, strip_whitespace
from transcribe.storage import clean, save_result



def _parse() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="transcribe", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", action="version", version=f"transcribe {__version__}")
    sub = p.add_subparsers(dest="command")

    file_p = sub.add_parser("file", help="transcribe existing audio files")
    file_p.add_argument("paths", nargs="+", metavar="AUDIO")
    file_p.add_argument("--json", action="store_true", help="machine-readable output")
    file_p.add_argument("--no-keep", action="store_true")
    file_p.add_argument("--notify", action="store_true",
                        help="show a macOS notification when each file finishes")
    file_p.add_argument("--background", action="store_true",
                        help="detach and run in the background so you can keep dictating")

    sub.add_parser("start", help="start the background engine")
    sub.add_parser("stop", help="stop the running engine")
    sub.add_parser("restart", help="restart the engine")

    serve_p = sub.add_parser("serve", help="run the engine in the foreground (for the app)")

    clean_p = sub.add_parser("clean", help="delete expired live data and file transcripts")
    clean_p.add_argument("--live-ttl-hours", type=float, default=None,
                         help="live dictation TTL (default: 1 hour)")
    clean_p.add_argument("--file-ttl-hours", type=float, default=None,
                         help="file transcript TTL (default: 168 hours)")
    clean_p.add_argument("--dry-run", action="store_true")

    cfg = sub.add_parser("config", help="view or change configuration")
    cfg.add_argument("action", nargs="?", choices=["show", "get", "set", "path"], default="show")
    cfg.add_argument("key", nargs="?", default=None)
    cfg.add_argument("value", nargs="?", default=None)

    doctor = sub.add_parser("doctor", help="diagnose the setup")

    app = sub.add_parser("app", help="build / install / launch the native menu-bar app")
    app.add_argument("action", nargs="?", choices=["build", "install", "launch", "path"], default="build")
    return p


def _smart(text: str) -> str:
    return apply_smart_text(strip_whitespace(text))


def _osa_escape(s: str) -> str:
    bs = chr(92)  # backslash
    return s.replace(bs, bs + bs).replace('"', bs + '"')


def notify(title: str, message: str) -> None:
    """Best-effort macOS notification (terminal-notifier, then osascript)."""
    tn = shutil.which("terminal-notifier")
    if tn:
        try:
            subprocess.run([tn, "-title", title, "-message", message],
                           capture_output=True, timeout=5)
            return
        except Exception:  # noqa: BLE001
            pass
    try:
        script = f'display notification "{_osa_escape(message)}" with title "{_osa_escape(title)}"'
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=5)
    except Exception:  # noqa: BLE001 - notifications are best-effort
        pass


def _daemonize() -> bool:
    """Fork into a background process that can still post notifications.

    Returns ``True`` in the child (keep working) and ``False`` in the parent
    (exit immediately). Uses a new process group in the *same* session so the
    child stays attached to the user's GUI session — meaning macOS
    notifications still deliver — while being detached from the launching
    process group so it survives the Quick Action / terminal exiting.
    """
    try:
        pid = os.fork()
    except OSError:
        return True
    if pid > 0:
        return False
    try:
        os.setpgrp()
    except OSError:
        pass
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    return True


def _maybe_keep(args, cfg, wav: str | None, text: str, result: dict,
                *, source: str = "live", source_path: str = "",
                transcript_path: str = ""):
    """Persist a session unless --no-keep; always honor per-kind cleanup."""
    if not getattr(args, "no_keep", False):
        save_result(text, result, wav,
                    source=source,
                    keep_transcripts=cfg.keep_transcripts,
                    source_path=source_path,
                    transcript_path=transcript_path)
    elif wav and os.path.exists(wav):
        os.remove(wav)
    clean(live_ttl_hours=cfg.live_cleanup_ttl_hours,
          file_ttl_hours=cfg.cleanup_ttl_hours)


# MARK: - engine control (start / stop / restart)

def _engine_health(port: int, timeout: float = 1.0) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=timeout) as resp:
            return resp.status == 200
    except (urllib.error.URLError, OSError):
        return False


def _engine_pids(port: int) -> list[int]:
    """PIDs of processes listening on the engine port."""
    try:
        out = subprocess.check_output(["lsof", "-ti", f"tcp:{port}", "-sTCP:LISTEN"],
                                      text=True, timeout=5)
    except (subprocess.SubprocessError, OSError):
        return []
    return sorted({int(line) for line in out.split() if line.strip().isdigit()})


def cmd_start(args, cfg) -> int:
    port = cfg.port
    if _engine_health(port):
        print(f"engine already running on port {port}")
        return 0
    log_path = os.path.join(os.path.dirname(config_path()), "engine.log")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    log = open(log_path, "ab")
    log.write(f"\n[{time.strftime('%Y-%m-%d %H:%M:%S')}] engine start\n".encode())
    proc = subprocess.Popen(
        [sys.executable, "-m", "transcribe", "serve"],
        stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,  # survive the terminal
    )
    deadline = time.time() + 60  # health binds before weights finish loading
    while time.time() < deadline:
        if _engine_health(port):
            print(f"engine running on port {port} (pid {proc.pid}, log: {log_path})")
            return 0
        if proc.poll() is not None:
            print(f"error: engine exited with code {proc.returncode} — see {log_path}",
                  file=sys.stderr)
            return 1
        time.sleep(0.25)
    print("error: engine did not become healthy in time — see "
          f"{log_path}", file=sys.stderr)
    return 1


def cmd_stop(args, cfg) -> int:
    port = cfg.port
    pids = _engine_pids(port)
    if not pids:
        print("engine not running")
        return 0
    for pid in pids:
        try:
            os.kill(pid, 15)  # SIGTERM: let the server finish in-flight work
        except ProcessLookupError:
            pass
    deadline = time.time() + 10
    while time.time() < deadline:
        if not _engine_pids(port):
            print(f"engine stopped (was on port {port})")
            return 0
        time.sleep(0.2)
    for pid in _engine_pids(port):
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
    print(f"engine force-stopped (was on port {port})")
    return 0


def cmd_restart(args, cfg) -> int:
    cmd_stop(args, cfg)
    return cmd_start(args, cfg)


# MARK: - dictation & files

def cmd_listen(args, cfg) -> int:
    if not check_accessibility():
        print("note: pasting needs Accessibility permission — `transcribe doctor` explains how.",
              file=sys.stderr)
    wav = record_interactive()
    print("Transcribing…", file=sys.stderr)
    result = transcribe(wav)
    text = _smart(result["text"])
    print(text)
    _maybe_keep(args, cfg, wav, text, result, source="live")
    paste_text(text)
    return 0


def cmd_file(args, cfg) -> int:
    if args.notify and args.paths:
        notify("Transcribe", f"Transcribing {os.path.basename(args.paths[0])}…")
    if args.background and not _daemonize():
        return 0  # parent exits; the detached child continues below

    results = []
    failures = []
    # Reuse one loaded transcriber for multi-selection: keeping one warm model
    # for the whole batch avoids a weight reload per file.
    transcriber = None
    for path in args.paths:
        if not os.path.exists(path):
            print(f"error: no such file: {path}", file=sys.stderr)
            failures.append(path)
            if args.notify:
                notify("Transcription failed", os.path.basename(path))
            continue
        try:
            if transcriber is None:
                transcriber = Transcriber()
            result = transcriber.transcribe(path)
        except Exception as exc:  # noqa: BLE001 - report and keep going
            print(f"error: failed to transcribe {path}: {exc}", file=sys.stderr)
            failures.append(path)
            if args.notify:
                notify("Transcription failed", f"{os.path.basename(path)} — {exc}")
            continue

        text = _smart(result["text"])
        md_path = write_transcript_markdown(path, text)
        results.append({"path": path, "markdown": md_path, **result, "text": text})
        if not args.json:
            print(f"--- {path} -> {md_path} ---")
            print(text)
        if args.notify:
            notify("Transcription saved", os.path.basename(md_path))
        _maybe_keep(args, cfg, None, text, result, source="file",
                    source_path=path, transcript_path=md_path)

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    return 1 if failures else 0


def cmd_serve(args, cfg) -> int:
    from transcribe.server import serve
    serve(verbose=True)
    return 0


def cmd_clean(args, cfg) -> int:
    live_ttl = (args.live_ttl_hours if args.live_ttl_hours is not None
                else cfg.live_cleanup_ttl_hours)
    file_ttl = (args.file_ttl_hours if args.file_ttl_hours is not None
                else cfg.cleanup_ttl_hours)
    removed = clean(dry_run=args.dry_run, live_ttl_hours=live_ttl,
                    file_ttl_hours=file_ttl)
    if removed:
        print(f"{'would remove' if args.dry_run else 'removed'} {len(removed)} file(s) "
              f"(live TTL {live_ttl:g}h; file TTL {file_ttl:g}h)")
        for path in removed[:10]:
            print("  ", path)
        if len(removed) > 10:
            print(f"   … and {len(removed) - 10} more")
    else:
        print("nothing to clean")
    return 0


def cmd_config(args, cfg) -> int:
    if args.action == "path":
        print(config_path())
        return 0
    if args.action == "show":
        for k, v in sorted(vars(cfg).items()):
            print(f"{k} = {v}")
        print(f"config file: {config_path()}")
        return 0
    if args.action == "get":
        if not args.key:
            print("error: `transcribe config get KEY`", file=sys.stderr)
            return 1
        value = getattr(cfg, args.key, None)
        print(value if value is not None else "")
        return 0 if value is not None else 1
    if args.action == "set":
        if not args.key or args.value is None:
            print("error: `transcribe config set KEY VALUE`", file=sys.stderr)
            return 1
        if not hasattr(cfg, args.key):
            print(f"error: unknown key {args.key!r}", file=sys.stderr)
            return 1
        current = getattr(cfg, args.key)
        if isinstance(current, bool):
            value = args.value.lower() in ("1", "true", "yes", "on")
        elif isinstance(current, float):
            value = float(args.value)
        elif isinstance(current, int):
            value = int(args.value)
        else:
            value = args.value
        setattr(cfg, args.key, value)
        path = save(cfg)
        print(f"{args.key} = {value}  ({path})")
        return 0
    return 0


def cmd_doctor(args, cfg) -> int:
    import subprocess

    cpu_brand = ""
    ram_gb = 0
    try:
        ram_gb = round(int(subprocess.check_output(
            ["sysctl", "-n", "hw.memsize"], text=True).strip()) / (1024 ** 3))
    except Exception:
        pass
    try:
        cpu_brand = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
    except Exception:
        pass
    hardware = f"{cpu_brand or 'Apple Silicon'}, {ram_gb} GB unified memory" if ram_gb \
        else (cpu_brand or "Apple Silicon")

    print("System Diagnostics")
    print("──────────────────")
    print(f"Hardware:     {hardware}")
    print("Model:        turbo-q4 (4-bit whisper-turbo, always warm)")
    print()

    ok = True

    def report(name, good, detail=""):
        nonlocal ok
        ok = ok and good
        print(f"{'✓' if good else '✗'} {name}{(' — ' + detail) if detail else ''}")

    from transcribe.audio import ffmpeg_path, find_input_device
    ff = ffmpeg_path()
    report("ffmpeg", bool(ff), ff or "install with `brew install ffmpeg`")

    try:
        import mlx_whisper  # noqa: F401
        report("mlx-whisper", True)
    except ImportError:
        report("mlx-whisper", False, "missing — reinstall with `make install`")

    dev = find_input_device()
    report("microphone device", True, f"avfoundation index {dev}")

    report("accessibility (for paste)", check_accessibility(),
           "System Settings → Privacy & Security → Accessibility → enable your terminal"
           if not check_accessibility() else "")

    stale = clean(dry_run=True, live_ttl_hours=cfg.live_cleanup_ttl_hours,
                  file_ttl_hours=cfg.cleanup_ttl_hours)
    report("no stale sessions", not stale,
           f"{len(stale)} file(s) past live {cfg.live_cleanup_ttl_hours:g}h / "
           f"file {cfg.cleanup_ttl_hours:g}h TTL — run `transcribe clean`")

    engine = "running" if _engine_health(cfg.port) else "not running"
    print(f"{'✓' if engine == 'running' else '•'} engine           {engine} "
          f"(start/stop/restart: `transcribe start|stop|restart`)")
    print()
    print("config file:", config_path())
    return 0 if ok else 1


def cmd_app(args, cfg) -> int:
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    build = os.path.join(repo, "app", "build.sh")
    if args.action == "path":
        print(os.path.join(repo, "app", "dist", "Transcribe.app"))
        return 0
    if not os.path.exists(build):
        print(f"error: {build} not found (run from a source checkout)", file=sys.stderr)
        return 1
    if args.action == "build":
        return subprocess.call(["bash", build])
    if args.action == "install":
        subprocess.call(["bash", build])
        src = os.path.join(repo, "app", "dist", "Transcribe.app")
        dst = "/Applications/Transcribe.app"
        if os.path.exists(dst):
            subprocess.call(["rm", "-rf", dst])
        shutil.copytree(src, dst)
        print(f"installed {dst}")
        return 0
    if args.action == "launch":
        subprocess.call(["bash", build])
        app = os.path.join(repo, "app", "dist", "Transcribe.app", "Contents", "MacOS", "Transcribe")
        subprocess.Popen([app])
        return 0
    return 1


def main(argv: list[str] | None = None) -> int:
    args = _parse().parse_args(argv)
    cfg = load()
    if args.command is None:
        # bare `transcribe` dictates from the microphone
        return cmd_listen(types.SimpleNamespace(no_keep=False), cfg)
    handlers = {
        "file": cmd_file, "serve": cmd_serve, "clean": cmd_clean,
        "config": cmd_config, "doctor": cmd_doctor, "app": cmd_app,
        "start": cmd_start, "stop": cmd_stop, "restart": cmd_restart,
    }
    return handlers[args.command](args, cfg)


if __name__ == "__main__":
    raise SystemExit(main())
