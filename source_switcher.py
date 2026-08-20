#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import time
from pathlib import Path

import firebase_admin
from firebase_admin import credentials, firestore

BASE = Path("/stream")
MAIN = BASE / "main"
NEXT = BASE / "next"
ACTIVE_FILE = BASE / ".active"
LOGO = Path("/app/hichrawi-logo-crop.png")
SOURCE_FILE = Path("/app/source.json")

POLL_SECONDS = 5
PREPARE_TIMEOUT = 180

running = []
db = None


def init_firebase():
    raw = os.environ.get("FIREBASE_SERVICE_ACCOUNT")

    if not raw:
        raise RuntimeError("FIREBASE_SERVICE_ACCOUNT is missing")

    info = json.loads(raw)

    if not firebase_admin._apps:
        firebase_admin.initialize_app(
            credentials.Certificate(info)
        )

    return firestore.client()


def active_name():
    try:
        value = ACTIVE_FILE.read_text().strip()

        if value in ("main", "next"):
            return value

    except Exception:
        pass

    return "main"


def set_active(name):
    tmp = ACTIVE_FILE.with_name(".active.tmp")

    tmp.write_text(name, encoding="utf-8")

    os.replace(tmp, ACTIVE_FILE)


def read_local_source():
    try:
        return (
            json.loads(SOURCE_FILE.read_text()).get("url") or ""
        ).strip()

    except Exception:
        return ""


def clear_dir(directory):
    directory.mkdir(parents=True, exist_ok=True)

    for item in directory.iterdir():

        if item.is_file() or item.is_symlink():

            try:
                item.unlink()

            except FileNotFoundError:
                pass


def is_ready(directory):

    playlist = directory / "stream.m3u8"

    if not playlist.is_file():
        return False

    if playlist.stat().st_size < 50:
        return False

    # Playlist must be recently updated.
    if time.time() - playlist.stat().st_mtime > 20:
        return False

    segments = list(directory.glob("*.ts"))

    if not segments:
        return False

    newest_segment = max(
        s.stat().st_mtime for s in segments
    )

    return newest_segment >= time.time() - 20


def start_ffmpeg(url, directory):

    clear_dir(directory)

    prefix = (
        "main"
        if directory == MAIN
        else "next"
    )

    segment_pattern = str(
        directory / f"{prefix}_%06d.ts"
    )

    playlist = str(
        directory / "stream.m3u8"
    )

    log_file = (
        Path("/tmp")
        / f"ffmpeg-{prefix}.log"
    )

    cmd = [
        "ffmpeg",

        "-hide_banner",
        "-loglevel", "info",

        # Read IPTV in real time.
        "-re",

        # IPTV reconnect options.
        "-reconnect", "1",
        "-reconnect_streamed", "1",
        "-reconnect_at_eof", "1",
        "-reconnect_delay_max", "10",
        "-rw_timeout", "15000000",

        # IPTV source.
        "-thread_queue_size", "2048",
        "-i", url,

        # Logo source.
        "-thread_queue_size", "64",
        "-loop", "1",
        "-framerate", "25",
        "-i", str(LOGO),

        # Logo overlay.
        "-filter_complex",
        "[1:v]scale=180:-1[logo];"
        "[0:v][logo]overlay=W-w-30,"
        "format=yuv420p[outv]",

        "-map", "[outv]",
        "-map", "0:a:0?",

        # Video.
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-profile:v", "main",
        "-level:v", "3.1",
        "-pix_fmt", "yuv420p",
        "-crf", "23",

        # Stable 25 FPS GOP.
        "-g", "150",
        "-keyint_min", "150",
        "-sc_threshold", "0",

        # Audio.
        "-c:a", "aac",
        "-profile:a", "aac_low",
        "-b:a", "128k",
        "-ar", "48000",
        "-ac", "2",

        # HLS.
        "-f", "hls",
        "-hls_time", "6",
        "-hls_list_size", "15",
        "-hls_delete_threshold", "10",

        "-hls_flags",
        "delete_segments+append_list",

        "-hls_segment_type",
        "mpegts",

        "-hls_allow_cache", "0",

        "-hls_playlist_type", "event",

        "-hls_segment_filename",
        segment_pattern,

        playlist,
    ]

    print(
        f"[SWITCHER] Starting FFmpeg for {directory.name}",
        flush=True
    )

    print(
        f"[SWITCHER] Source: {url}",
        flush=True
    )

    print(
        f"[SWITCHER] Log file: {log_file}",
        flush=True
    )

    log_handle = open(
        log_file,
        "w",
        buffering=1
    )

    process = subprocess.Popen(
        cmd,
        stdout=log_handle,
        stderr=subprocess.STDOUT
    )

    return process, log_handle


def stop_process(proc):

    if proc and proc.poll() is None:

        try:
            proc.terminate()

            proc.wait(timeout=10)

        except Exception:

            try:
                proc.kill()

            except Exception:
                pass


def set_status(ref, data):
    ref.set(data, merge=True)


def wait_until_ready(
    process,
    directory,
    timeout
):

    deadline = time.time() + timeout

    while time.time() < deadline:

        # FFmpeg died.
        if process.poll() is not None:

            print(
                f"[SWITCHER] FFmpeg stopped "
                f"while preparing {directory.name}",
                flush=True
            )

            return False

        if is_ready(directory):

            print(
                f"[SWITCHER] HLS READY: {directory.name}",
                flush=True
            )

            return True

        time.sleep(3)

    print(
        f"[SWITCHER] PREPARE TIMEOUT: "
        f"{directory.name}",
        flush=True
    )

    return False


def main():

    global db

    db = init_firebase()

    ref = (
        db
        .collection("settings")
        .document("stream")
    )

    MAIN.mkdir(
        parents=True,
        exist_ok=True
    )

    NEXT.mkdir(
        parents=True,
        exist_ok=True
    )

    current = (
        ref.get().to_dict()
        or {}
    )

    configured = (
        current.get("activeSource")
        or current.get("url")
        or read_local_source()
    ).strip()

    active = active_name()

    active_proc = None
    active_log = None

    # -------------------------------------------------
    # Initial stream
    # -------------------------------------------------

    if (
        not is_ready(MAIN)
        and not is_ready(NEXT)
        and configured
    ):

        active = "main"

        set_active("main")

        active_proc, active_log = start_ffmpeg(
            configured,
            MAIN
        )

        ok = wait_until_ready(
            active_proc,
            MAIN,
            PREPARE_TIMEOUT
        )

        if ok:

            set_status(
                ref,
                {
                    "url": configured,
                    "activeSource": configured,
                    "sourceStatus": "active"
                }
            )

        else:

            stop_process(active_proc)

            active_proc = None

            if active_log:
                active_log.close()

            set_status(
                ref,
                {
                    "sourceStatus": "failed",
                    "sourceError":
                        "المصدر الحالي لم يصبح HLS جاهزاً"
                }
            )

    # -------------------------------------------------
    # Main switch loop
    # -------------------------------------------------

    while True:

        data = (
            ref.get().to_dict()
            or {}
        )

        requested = (
            data.get("requestedSource")
            or ""
        ).strip()

        current_url = (
            data.get("activeSource")
            or data.get("url")
            or configured
        ).strip()

        status = data.get(
            "sourceStatus",
            ""
        )

        # -------------------------------------------------
        # New source requested
        # -------------------------------------------------

        if (
            requested
            and requested != current_url
            and status == "pending"
        ):

            active = active_name()

            target = (
                NEXT
                if active == "main"
                else MAIN
            )

            target_name = (
                "next"
                if target == NEXT
                else "main"
            )

            print(
                f"[SWITCHER] Preparing new source "
                f"in {target_name}",
                flush=True
            )

            candidate = None
            candidate_log = None

            try:

                candidate, candidate_log = start_ffmpeg(
                    requested,
                    target
                )

                ok = wait_until_ready(
                    candidate,
                    target,
                    PREPARE_TIMEOUT
                )

                if ok:

                    old_dir = (
                        MAIN
                        if active == "main"
                        else NEXT
                    )

                    old_proc = active_proc
                    old_log = active_log

                    # -----------------------------------------
                    # Atomic switch
                    # -----------------------------------------

                    set_active(target_name)

                    active_proc = candidate
                    active_log = candidate_log

                    configured = requested

                    set_status(
                        ref,
                        {
                            "url": requested,
                            "activeSource": requested,
                            "requestedSource": requested,
                            "sourceStatus": "active",
                            "sourceChangedAt":
                                firestore.SERVER_TIMESTAMP,
                            "sourceError": firestore.DELETE_FIELD
                        }
                    )

                    print(
                        f"[SWITCHER] SOURCE SWITCHED "
                        f"TO {target_name}",
                        flush=True
                    )

                    # Old pipeline can now stop.
                    if (
                        old_proc
                        and old_proc is not candidate
                    ):

                        stop_process(old_proc)

                    if old_log:

                        try:
                            old_log.close()

                        except Exception:
                            pass

                else:

                    stop_process(candidate)

                    if candidate_log:

                        try:
                            candidate_log.close()

                        except Exception:
                            pass

                    clear_dir(target)

                    set_status(
                        ref,
                        {
                            "sourceStatus": "failed",
                            "sourceError":
                                "المصدر الجديد لم يصبح HLS جاهزاً خلال 3 دقائق"
                        }
                    )

                    print(
                        "[SWITCHER] SOURCE SWITCH FAILED",
                        flush=True
                    )

            except Exception as exc:

                print(
                    f"[SWITCHER] ERROR: {exc}",
                    flush=True
                )

                if candidate:

                    stop_process(candidate)

                if candidate_log:

                    try:
                        candidate_log.close()

                    except Exception:
                        pass

                clear_dir(target)

                set_status(
                    ref,
                    {
                        "sourceStatus": "failed",
                        "sourceError": str(exc)
                    }
                )

        # -------------------------------------------------
        # Active FFmpeg died
        # -------------------------------------------------

        if (
            active_proc
            and active_proc.poll() is not None
        ):

            print(
                "[SWITCHER] Active FFmpeg stopped. "
                "Restarting current source...",
                flush=True
            )

            active_proc = None

            if active_log:

                try:
                    active_log.close()

                except Exception:
                    pass

                active_log = None

            active = active_name()

            restart_dir = (
                MAIN
                if active == "main"
                else NEXT
            )

            current = (
                ref.get().to_dict()
                or {}
            )

            url = (
                current.get("activeSource")
                or current.get("url")
                or configured
            ).strip()

            if url:

                active_proc, active_log = start_ffmpeg(
                    url,
                    restart_dir
                )

                set_status(
                    ref,
                    {
                        "sourceStatus":
                            "restarting"
                    }
                )

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":

    signal.signal(
        signal.SIGTERM,
        lambda *_: (
            _ for _ in ()
        ).throw(SystemExit)
    )

    main()
