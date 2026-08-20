"""Transcribe command-line interface.

Usage:
    transcribe                  interactive dictation (Enter to start/stop)
    transcribe listen           same as above, with flags
    transcribe file AUDIO...    transcribe existing files
    transcribe serve            localhost engine server for the menu-bar app
    transcribe clean            remove recordings/transcripts older than TTL
    transcribe config           get/set configuration values
    transcribe models           list models and what is installed
    transcribe doctor           diagnose the setup (ffmpeg, backend, perms)
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

from transcribe import __version__
from transcribe.audio import record_interactive
from transcribe.config import Config, config_path, load, save
from transcribe.engine import MODELS, Transcriber, available_backends, detect_backend, transcribe
from transcribe.paste import check_accessibility, paste_text
from transcribe.smarttext import apply_smart_text, strip_whitespace
from transcribe.storage import clean, save_session

APP_BUILD_SH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "build.sh")


def _parse() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="transcribe", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", action="version", version=f"transcribe {__version__}")
    sub = p.add_subparsers(dest="command")

    listen = sub.add_parser("listen", help="record from the microphone and transcribe")
    listen.add_argument("-s", "--seconds", type=float, default=None,
                        help="record for a fixed number of seconds (default: until Enter)")
    listen.add_argument("--paste", dest="paste", action="store_true", default=None,
                        help="paste into the focused app (default: from config)")
    listen.add_argument("--no-paste", dest="paste", action="store_false")
    listen.add_argument("--smart-text", dest="smart_text", action="store_true", default=None)
    listen.add_argument("--no-smart-text", dest="smart_text", action="store_false")
    listen.add_argument("-l", "--language", default=None, help="auto | en | it | …")
    listen.add_argument("-m", "--model", default=None, help="model alias or HF repo")
    listen.add_argument("--no-keep", action="store_true", help="delete audio+transcript immediately")

    file_p = sub.add_parser("file", help="transcribe existing audio files")
    file_p.add_argument("paths", nargs="+", metavar="AUDIO")
    file_p.add_argument("-l", "--language", default="en",
                        help="transcription language (default: en for files)")
    file_p.add_argument("-m", "--model", default=None,
                        help="model alias or HF repo (default: turbo)")
    file_p.add_argument("--smart-text", dest="smart_text", action="store_true", default=None)
    file_p.add_argument("--no-smart-text", dest="smart_text", action="store_false")
    file_p.add_argument("--json", action="store_true", help="machine-readable output")
    file_p.add_argument("--no-keep", action="store_true")
    file_p.add_argument("--notify", action="store_true",
                        help="show a macOS notification when each file finishes")
    file_p.add_argument("--background", action="store_true",
                        help="detach and run in the background so you can keep dictating")

    serve_p = sub.add_parser("serve", help="run the localhost engine server (for the app)")
    serve_p.add_argument("--port", type=int, default=None)
    serve_p.add_argument("--no-warm", action="store_true", help="don't preload the model")

    clean_p = sub.add_parser("clean", help="delete expired live data and file transcripts")
    clean_p.add_argument("--ttl-hours", type=float, default=None,
                         help="legacy override: use one TTL for both kinds")
    clean_p.add_argument("--live-ttl-hours", type=float, default=None,
                         help="live dictation TTL (default: 1 hour)")
    clean_p.add_argument("--file-ttl-hours", type=float, default=None,
                         help="file transcript TTL (default: 168 hours)")
    clean_p.add_argument("--dry-run", action="store_true")

    cfg = sub.add_parser("config", help="view or change configuration")
    cfg.add_argument("action", nargs="?", choices=["show", "get", "set", "path"], default="show")
    cfg.add_argument("key", nargs="?", default=None)
    cfg.add_argument("value", nargs="?", default=None)

    sub.add_parser("models", help="list models and installed status")

    doctor = sub.add_parser("doctor", help="diagnose the setup")
    doctor.add_argument("--check-mic", action="store_true", help="also probe the microphone")

    app = sub.add_parser("app", help="build / install / launch the native menu-bar app")
    app.add_argument("action", nargs="?", choices=["build", "install", "launch", "path"], default="build")
    return p


def _transcribe_args(args, cfg: Config) -> dict:
    return {
        "model": args.model or cfg.model,
        "backend": cfg.backend,
        "language": args.language or cfg.language,
    }


def _smart(text: str, enabled: bool | None, cfg: Config) -> str:
    text = strip_whitespace(text)
    smart = cfg.smart_text if enabled is None else enabled
    if smart:
        text = apply_smart_text(text)
    return text


def _osa_escape(s: str) -> str:
    bs = chr(92)  # backslash
    return s.replace(bs, bs + bs).replace('"', bs + '"')


def notify(title: str, message: str) -> None:
    """Best-effort macOS notification.

    Uses ``terminal-notifier`` when available (reliable, session-attached) and
    otherwise falls back to ``osascript display notification``. Silent no-op if
    neither is usable.
    """
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
    process group so it survives the Quick Action / terminal exiting. Falls
    back to foreground if forking is unavailable.
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


def _write_markdown(audio_path: str, text: str) -> str:
    """Write the transcript as ``<basename>.md`` next to the audio file.

    Returns the markdown path (same directory, same stem as the source audio).
    """
    nl = chr(10)
    base = os.path.splitext(audio_path)[0]
    md_path = base + ".md"
    title = os.path.splitext(os.path.basename(audio_path))[0]
    content = f"# {title}{nl}{nl}{text}{nl}"
    with open(md_path, "w", encoding="utf-8") as fh:
        fh.write(content)
    return md_path

def _maybe_keep(args, cfg: Config, wav: str | None, text: str, result: dict,
                *, source: str = "live", source_path: str = "",
                transcript_path: str = ""):
    """Persist a session unless --no-keep; always honor per-kind cleanup."""
    if not getattr(args, "no_keep", False):
        try:
            save_session(
                wav, text,
                duration=result.get("duration", 0.0),
                model=result.get("model", ""),
                language=result.get("language", ""),
                source=source,
                keep_transcripts=cfg.keep_transcripts,
                source_path=source_path,
                transcript_path=transcript_path,
            )
        except OSError:
            pass
    elif wav and os.path.exists(wav):
        os.remove(wav)
    clean(live_ttl_hours=cfg.live_cleanup_ttl_hours,
          file_ttl_hours=cfg.cleanup_ttl_hours)


def cmd_listen(args, cfg: Config) -> int:
    if cfg.paste and not check_accessibility():
        print("note: pasting needs Accessibility permission — `transcribe doctor` explains how.",
              file=sys.stderr)
    wav = record_interactive(device=cfg.device, sample_rate=cfg.sample_rate)
    print(f"Transcribing…", file=sys.stderr)
    result = transcribe(wav, **_transcribe_args(args, cfg))
    text = _smart(result["text"], args.smart_text, cfg)
    print(text)
    _maybe_keep(args, cfg, wav, text, result, source="live")
    if cfg.paste and args.paste is not False:
        paste_text(text)
    return 0


def cmd_file(args, cfg: Config) -> int:
    if args.notify and args.paths:
        notify("Transcribe", f"Transcribing {os.path.basename(args.paths[0])}…")
    if args.background and not _daemonize():
        return 0  # parent exits; the detached child continues below

    results = []
    failures = []
    # Reuse one loaded transcriber for multi-selection. Constructing a new
    # faster-whisper model for every file is needlessly expensive; MLX also
    # benefits from keeping one backend instance for the whole batch.
    transcriber = None
    transcribe_options = _transcribe_args(args, cfg)
    for path in args.paths:
        if not os.path.exists(path):
            print(f"error: no such file: {path}", file=sys.stderr)
            failures.append(path)
            if args.notify:
                notify("Transcription failed", os.path.basename(path))
            continue
        try:
            if transcriber is None:
                transcriber = Transcriber(**transcribe_options)
            result = transcriber.transcribe(path)
        except Exception as exc:  # noqa: BLE001 - report and keep going
            print(f"error: failed to transcribe {path}: {exc}", file=sys.stderr)
            failures.append(path)
            if args.notify:
                notify("Transcription failed", f"{os.path.basename(path)} — {exc}")
            continue

        text = _smart(result["text"], args.smart_text, cfg)
        md_path = _write_markdown(path, text)
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


def cmd_serve(args, cfg: Config) -> int:
    from transcribe.server import serve
    serve(port=args.port, warm=None if not args.no_warm else False, verbose=True)
    return 0


def cmd_clean(args, cfg: Config) -> int:
    if args.ttl_hours is not None:
        live_ttl = file_ttl = args.ttl_hours
    else:
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


def cmd_config(args, cfg: Config) -> int:
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


def _model_cached(repo: str) -> bool:
    """True if the HF snapshot for this repo is already in the local cache."""
    import os as _os
    cache = _os.path.expanduser("~/.cache/huggingface/hub")
    safe = repo.replace("/", "--")
    return _os.path.isdir(_os.path.join(cache, f"models--{safe}"))


def cmd_models(args, cfg: Config) -> int:
    backends = available_backends()
    print(f"installed backends: {', '.join(backends) or 'none'}")
    print(f"default backend:    {detect_backend(cfg.backend)}")
    print()
    for alias, info in MODELS.items():
        print(f"{alias:16s} {info['languages']}")
        for b in ("mlx", "faster"):
            mark = "downloaded" if _model_cached(info[b]) else ("backend ready" if b in backends else "missing")
            print(f"    {b:8s} {info[b]}  [{mark}]")
    return 0


def cmd_doctor(args, cfg: Config) -> int:
    from transcribe.engine import detect_system_info
    info = detect_system_info()

    print("System Diagnostics & Recommendations")
    print("────────────────────────────────────")
    print(f"Hardware:            {info['hardware_desc']}")
    print(f"Recommended Backend: {info['recommended_backend_pkg']}")
    print(f"Recommended Model:   {info['recommended_model']} ({info['model_reason']})")
    print(f"Active Model:        {cfg.model} (language: {cfg.language})")
    print()

    ok = True

    def report(name, good, detail=""):
        nonlocal ok
        ok = ok and good
        print(f"{'✓' if good else '✗'} {name}{(' — ' + detail) if detail else ''}")

    from transcribe.audio import ffmpeg_path
    ff = ffmpeg_path()
    report("ffmpeg", bool(ff), ff or "install with `brew install ffmpeg`")

    backends = available_backends()
    backend_good = bool(backends)
    if not backends:
        detail = f"Missing! Run: `{info['install_cmd']}`"
    else:
        detail = f"available: {', '.join(backends)}"
    report("transcription backend", backend_good, detail)

    from transcribe.audio import find_input_device
    dev = find_input_device(cfg.device)
    report("microphone device", True, f"avfoundation index {dev}")

    if cfg.paste:
        report("accessibility (for paste)", check_accessibility(),
               "System Settings → Privacy & Security → Accessibility → enable your terminal")

    stale = clean(dry_run=True, live_ttl_hours=cfg.live_cleanup_ttl_hours,
                  file_ttl_hours=cfg.cleanup_ttl_hours)
    report("no stale sessions", not stale,
           f"{len(stale)} file(s) past live {cfg.live_cleanup_ttl_hours:g}h / "
           f"file {cfg.cleanup_ttl_hours:g}h TTL — run `transcribe clean`")
    print()
    print("config file:", config_path())
    return 0 if ok else 1


def cmd_app(args, cfg: Config) -> int:
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
    if args.command in (None, "listen"):
        if args.command is None:
            # bare `transcribe` behaves like `listen`
            return cmd_listen(_parse().parse_args(["listen"]), cfg)
        return cmd_listen(args, cfg)
    handlers = {
        "file": cmd_file, "serve": cmd_serve, "clean": cmd_clean,
        "config": cmd_config, "models": cmd_models, "doctor": cmd_doctor,
        "app": cmd_app,
    }
    return handlers[args.command](args, cfg)


if __name__ == "__main__":
    raise SystemExit(main())
