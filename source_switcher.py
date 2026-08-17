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
GRACE_SECONDS = 45

running = []
db = None

def init_firebase():
    raw = os.environ.get("FIREBASE_SERVICE_ACCOUNT")
    if not raw:
        raise RuntimeError("FIREBASE_SERVICE_ACCOUNT is missing")
    info = json.loads(raw)
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(info))
    return firestore.client()

def active_name():
    try:
        value = ACTIVE_FILE.read_text().strip()
        return value if value in ("main", "next") else "main"
    except Exception:
        return "main"

def set_active(name):
    tmp = ACTIVE_FILE.with_name(".active.tmp")
    tmp.write_text(name, encoding="utf-8")
    os.replace(tmp, ACTIVE_FILE)

def read_local_source():
    try:
        return (json.loads(SOURCE_FILE.read_text()).get("url") or "").strip()
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
    if not playlist.is_file() or playlist.stat().st_size < 50:
        return False
    if time.time() - playlist.stat().st_mtime > 20:
        return False
    # Require a recently written segment.
    segments = list(directory.glob("*.ts"))
    if not segments:
        return False
    return max(s.stat().st_mtime for s in segments) >= time.time() - 20

def start_ffmpeg(url, directory):
    clear_dir(directory)
    # Unique segment prefix per pipeline prevents old/new segment name collisions.
    prefix = "main" if directory == MAIN else "next"
    segment_pattern = str(directory / f"{prefix}_%06d.ts")
    playlist = str(directory / "stream.m3u8")

    cmd = [
        "ffmpeg",
        "-hide_banner", "-loglevel", "warning",
        "-reconnect", "1",
        "-reconnect_streamed", "1",
        "-reconnect_at_eof", "1",
        "-reconnect_delay_max", "10",
        "-rw_timeout", "15000000",
        "-i", url,
        "-i", str(LOGO),
        "-filter_complex",
        "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-c:a", "copy",
        "-f", "hls",
        "-hls_time", "6",
        "-hls_list_size", "15",
        "-hls_flags", "delete_segments+append_list",
        "-hls_segment_filename", segment_pattern,
        playlist,
    ]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

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

def cleanup_old(directory):
    # Keep old HLS files for a short grace period after a successful switch.
    time.sleep(GRACE_SECONDS)
    clear_dir(directory)

def set_status(ref, data):
    ref.set(data, merge=True)

def main():
    global db
    db = init_firebase()
    ref = db.collection("settings").document("stream")

    MAIN.mkdir(parents=True, exist_ok=True)
    NEXT.mkdir(parents=True, exist_ok=True)

    # Preserve an already-running legacy stream on a live container.
    # If MAIN/NEXT are empty, start the configured source into MAIN.
    current = ref.get().to_dict() or {}
    configured = (current.get("activeSource") or current.get("url") or read_local_source()).strip()

    active = active_name()
    active_proc = None

    if not is_ready(MAIN) and not is_ready(NEXT) and configured:
        active = "main"
        set_active("main")
        active_proc = start_ffmpeg(configured, MAIN)
        deadline = time.time() + PREPARE_TIMEOUT
        while time.time() < deadline:
            if active_proc.poll() is not None:
                break
            if is_ready(MAIN):
                set_status(ref, {
                    "url": configured,
                    "activeSource": configured,
                    "sourceStatus": "active"
                })
                break
            time.sleep(2)

        if not is_ready(MAIN):
            stop_process(active_proc)
            active_proc = None
            set_status(ref, {"sourceStatus": "failed"})
            # Do not create a fake active stream.

    # If a legacy FFmpeg is already producing /stream/stream.m3u8, we do not
    # kill it here. This process is intended to be activated through the new
    # Docker image after the old pipeline is no longer PID 1.
    while True:
        data = ref.get().to_dict() or {}
        requested = (data.get("requestedSource") or "").strip()
        current_url = (data.get("activeSource") or data.get("url") or configured).strip()
        status = data.get("sourceStatus", "")

        if requested and requested != current_url and status == "pending":
            active = active_name()
            target = NEXT if active == "main" else MAIN
            target_name = "next" if target == NEXT else "main"

            candidate = start_ffmpeg(requested, target)
            ok = False
            deadline = time.time() + PREPARE_TIMEOUT

            while time.time() < deadline:
                if candidate.poll() is not None:
                    break
                if is_ready(target):
                    ok = True
                    break
                time.sleep(3)

            if ok:
                old_dir = MAIN if active == "main" else NEXT
                old_proc = active_proc

                # Atomic selector change. New playlist is ready before this point.
                set_active(target_name)

                active_proc = candidate
                configured = requested
                set_status(ref, {
                    "url": requested,
                    "activeSource": requested,
                    "requestedSource": requested,
                    "sourceStatus": "active",
                    "sourceChangedAt": firestore.SERVER_TIMESTAMP,
                })

                # Keep old HLS files available for a grace period, then stop old
                # process. The candidate is already the active process.
                if old_proc and old_proc is not candidate:
                    stop_process(old_proc)
                # Do not immediately delete old_dir; the HTTP server may still
                # receive late requests for old segment URLs.
                # Its files are cleaned on the next use of that directory.
            else:
                stop_process(candidate)
                clear_dir(target)
                set_status(ref, {
                    "sourceStatus": "failed",
                    "sourceError": "المصدر الجديد لم يصبح HLS جاهزاً خلال 3 دقائق"
                })

        if active_proc and active_proc.poll() is not None:
            # Never deliberately switch to a dead candidate. If the active
            # pipeline dies, restart the same active source automatically.
            active_proc = None
            active = active_name()
            restart_dir = MAIN if active == "main" else NEXT
            current = ref.get().to_dict() or {}
            url = (current.get("activeSource") or current.get("url") or configured).strip()
            if url:
                active_proc = start_ffmpeg(url, restart_dir)
                set_status(ref, {"sourceStatus": "restarting"})

        time.sleep(POLL_SECONDS)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit))
    main()
