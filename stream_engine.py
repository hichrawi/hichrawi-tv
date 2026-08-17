#!/usr/bin/env python3
import json
import os
import shutil
import signal
import subprocess
import time
import urllib.request
from pathlib import Path

STREAM_ROOT = Path("/stream")
STATE_FILE = Path("/app/stream_state.json")
CONTROL_FILE = Path("/app/source_request.json")
SOURCE_FILE = Path("/app/source.json")
VIDEO_ROOT = Path("/app/videos")
LOG = Path("/app/stream_engine.log")

STREAM_ROOT.mkdir(parents=True, exist_ok=True)
VIDEO_ROOT.mkdir(parents=True, exist_ok=True)

active_proc = None
active_dir = "source_a"
request_mtime = 0

def log(msg):
    line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + str(msg)
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")

def write_state(status=None, **extra):
    data = {"active_dir": active_dir}
    if status:
        data["status"] = status
    data.update(extra)
    STATE_FILE.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def wait_ready(folder, timeout=90):
    playlist = folder / "stream.m3u8"
    end = time.time() + timeout
    while time.time() < end:
        if playlist.exists() and playlist.stat().st_size > 100:
            text = playlist.read_text(errors="ignore")
            if "#EXTINF" in text:
                segments = [x for x in text.splitlines() if x.endswith(".ts")]
                if len(segments) >= 2:
                    return True
        time.sleep(1)
    return False

def stop_process(proc):
    if not proc:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)

def resolve_local_or_url(item):
    item = str(item or "").strip()
    if not item:
        return None
    if item.startswith("/videos/"):
        rel = item[len("/videos/"):]
        p = (VIDEO_ROOT / rel).resolve()
        if VIDEO_ROOT.resolve() in p.parents and p.is_file():
            return str(p)
        return None
    # Direct relative paths from the Railway video volume.
    if not item.startswith("http://") and not item.startswith("https://") and not item.startswith("file://"):
        p = (VIDEO_ROOT / item.lstrip("/")).resolve()
        if VIDEO_ROOT.resolve() in p.parents and p.is_file():
            return str(p)
    if item.startswith("file://"):
        return item
    if item.startswith("http://") or item.startswith("https://"):
        return item
    p = (VIDEO_ROOT / item).resolve()
    if VIDEO_ROOT.resolve() in p.parents and p.is_file():
        return str(p)
    return None

def make_concat_file(folder, items):
    concat = folder / "playlist.txt"
    lines = []
    for item in items:
        value = resolve_local_or_url(item)
        if not value:
            continue
        # concat demuxer syntax; escape single quotes.
        value = value.replace("'", "'\\''")
        lines.append("file '" + value + "'")
    concat.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return concat, len(lines)

def ffmpeg_command(source, folder):
    out = folder / "stream.m3u8"
    seg = folder / "seg%06d.ts"
    common = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning",
        "-y"
    ]

    typ = source.get("type", "iptv")
    if typ == "videos":
        items = source.get("items", [])
        concat, count = make_concat_file(folder, items)
        log(f"Video playlist prepared: {count} item(s)")
        if count == 0:
            raise RuntimeError("لا توجد فيديوهات صالحة في Playlist")
        # Loop the entire playlist forever. A single video therefore repeats
        # indefinitely, while multiple videos play sequentially and then restart.
        input_args = [
            "-re", "-stream_loop", "-1",
            "-f", "concat", "-safe", "0", "-i", str(concat)
        ]
    elif typ == "iptv":
        url = str(source.get("url", "")).strip()
        if not url:
            raise RuntimeError("رابط IPTV فارغ")
        input_args = [
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_at_eof", "1",
            "-reconnect_delay_max", "10",
            "-rw_timeout", "15000000",
            "-i", url
        ]
    else:
        raise RuntimeError("نوع المصدر غير مدعوم حالياً: " + typ)

    return common + input_args + [
        "-i", "/app/hichrawi-logo-crop.png",
        "-filter_complex",
        "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30",
        "-map", "0:v:0", "-map", "0:a?",
        "-c:v", "libx264", "-preset", "veryfast",
        "-c:a", "aac", "-b:a", "128k",
        "-f", "hls",
        "-hls_time", "6",
        "-hls_list_size", "15",
        "-hls_flags", "delete_segments+append_list",
        "-hls_segment_filename", str(seg),
        str(out)
    ]

def start_candidate(source, folder):
    if folder.exists():
        shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)

    log("Preparing new source: " + source.get("name", source.get("type", "unknown")))

    if source.get("type") == "youtube":
        url = str(source.get("url", "")).strip()
        if not url:
            raise RuntimeError("رابط YouTube فارغ")
        cmd = ["python3", "/app/youtube_runner.py", url, str(folder)]
        log("YouTube runner: " + url)
    else:
        cmd = ffmpeg_command(source, folder)
        log("FFmpeg: " + " ".join(cmd[:12]) + " ...")

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT
    )

    if wait_ready(folder, 90):
        return proc
    stop_process(proc)
    shutil.rmtree(folder, ignore_errors=True)
    return None

def switch_to(source):
    global active_proc, active_dir

    target = "source_b" if active_dir == "source_a" else "source_a"
    target_dir = STREAM_ROOT / target

    write_state(
        "switching",
        source_type=source.get("type", "iptv"),
        source_name=source.get("name", ""),
        requested_at=time.time(),
        message="جاري تحضير المصدر الجديد..."
    )

    proc = start_candidate(source, target_dir)
    if not proc:
        log("New source failed readiness check; keeping current source.")
        write_state(
            "running",
            source_type=source.get("type", "iptv"),
            source_name=source.get("name", ""),
            switch_failed=True,
            error="المصدر الجديد لم يصبح جاهزاً، تم الإبقاء على البث الحالي.",
            message="فشل التبديل — البث الحالي مستمر."
        )
        return False

    old_proc = active_proc
    old_dir = active_dir

    # Flip only after the new HLS playlist has valid segments.
    active_proc = proc
    active_dir = target
    write_state(
        "switched",
        source_type=source.get("type", "iptv"),
        source_name=source.get("name", ""),
        requested_at=time.time(),
        switched_at=time.time(),
        switch_failed=False,
        message="تم التبديل بنجاح إلى المصدر الجديد."
    )

    stop_process(old_proc)
    log(f"Source switched: {old_dir} -> {active_dir}")
    return True

def initial_source():
    data = read_json(SOURCE_FILE, {})
    return {
        "type": "iptv",
        "name": "Current IPTV",
        "url": data.get("url", ""),
        "items": []
    }

def read_control():
    data = read_json(CONTROL_FILE, {})
    if not data or not data.get("_received_from_api"):
        return None
    return data

def main():
    global request_mtime

    write_state("starting")
    source = initial_source()

    # Start current source first.
    proc = start_candidate(source, STREAM_ROOT / active_dir)
    if proc:
        global active_proc
        active_proc = proc
        write_state("running", source_type=source["type"], source_name=source["name"])
        log("Initial source is running.")
    else:
        write_state("waiting")
        log("Initial source is not ready; will retry.")

    while True:
        # If active FFmpeg died, retry the same source automatically.
        if active_proc is None or active_proc.poll() is not None:
            log("FFmpeg stopped. Rebuilding current source automatically.")
            old_source = source
            proc = start_candidate(old_source, STREAM_ROOT / active_dir)
            if proc:
                active_proc = proc
                write_state("running", source_type=source.get("type","iptv"), source_name=source.get("name",""))
            else:
                active_proc = None
                write_state("waiting")
                time.sleep(5)
                continue

        # Watch source request file.
        try:
            mt = CONTROL_FILE.stat().st_mtime
        except FileNotFoundError:
            mt = 0

        if mt and mt != request_mtime:
            request_mtime = mt
            requested = read_control()
            if requested:
                log("SOURCE REQUEST DETECTED: " + json.dumps({
                    "type": requested.get("type"),
                    "name": requested.get("name"),
                    "url": requested.get("url", ""),
                    "items": len(requested.get("items", []))
                }, ensure_ascii=False))
                # Never replace current source until candidate is ready.
                ok = switch_to(requested)
                if ok:
                    source = requested
                    try:
                        CONTROL_FILE.unlink()
                    except Exception:
                        pass
                else:
                    write_state(
                        "running",
                        source_type=source.get("type","iptv"),
                        source_name=source.get("name",""),
                        switch_failed=True
                    )

        time.sleep(2)

if __name__ == "__main__":
    main()
