#!/usr/bin/env python3
import json
import os
import shutil
import signal
import subprocess
import time
import urllib.request
from pathlib import Path
from source_adapter import input_args as universal_input_args

STREAM_ROOT = Path("/stream")
STATE_FILE = Path("/app/stream_state.json")
CONTROL_FILE = Path("/app/source_request.json")
FALLBACK_FILE = Path("/stream/fallback_source.json")
SCHEDULE_FILE = Path("/stream/schedule.json")
LOGO_FILE = Path("/stream/logo.png")
LOGO_REQUEST_FILE = Path("/stream/logo_request.json")
ANNOUNCEMENT_FILE = Path("/stream/announcement.json")
ANNOUNCEMENT_TEXT_FILE = Path("/stream/announcement.txt")
SOURCE_FILE = Path("/app/source.json")
VIDEO_ROOT = Path("/app/videos")
LOG = Path("/app/stream_engine.log")

STREAM_ROOT.mkdir(parents=True, exist_ok=True)
VIDEO_ROOT.mkdir(parents=True, exist_ok=True)

active_proc = None
active_dir = "source_a"
request_mtime = 0
schedule_mtime = 0
last_schedule_key = ""
announcement_mtime = 0

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

def read_announcement():
    data = read_json(ANNOUNCEMENT_FILE, {})
    if not isinstance(data, dict):
        return {"enabled": False}

    enabled = bool(data.get("enabled", False))
    raw_text = str(data.get("text", "") or "").strip()
    if not enabled or not raw_text:
        return {"enabled": False}

    # Keep the text in a UTF-8 file so FFmpeg drawtext does not need
    # shell/filter escaping for Arabic or punctuation.
    try:
        ANNOUNCEMENT_TEXT_FILE.write_text(raw_text, encoding="utf-8")
    except Exception as e:
        log("ANNOUNCEMENT TEXT WRITE FAILED: " + str(e))
        return {"enabled": False}

    try:
        speed = float(data.get("speed", 2.0) or 2.0)
    except Exception:
        speed = 2.0
    speed = max(0.5, min(speed, 8.0))

    try:
        font_size = int(data.get("fontSize", data.get("size", 36)) or 36)
    except Exception:
        font_size = 36
    font_size = max(18, min(font_size, 80))

    bg = str(data.get("backgroundColor", data.get("bgColor", "#e00000")) or "#e00000").strip()
    fg = str(data.get("textColor", data.get("color", "#ffffff")) or "#ffffff").strip()

    # FFmpeg drawbox/drawtext accept 0xRRGGBB[AA]. Normalize common #RRGGBB.
    def ff_color(value, default):
        v = value.lstrip("#")
        if len(v) == 6 and all(c in "0123456789abcdefABCDEF" for c in v):
            return "0x" + v
        if len(v) == 8 and all(c in "0123456789abcdefABCDEF" for c in v):
            return "0x" + v
        return default

    return {
        "enabled": True,
        "speed": speed,
        "font_size": font_size,
        "bg": ff_color(bg, "0xe00000"),
        "fg": ff_color(fg, "0xffffff"),
    }


def announcement_filter(video_label, announcement):
    if not announcement.get("enabled"):
        return video_label

    # Bottom ticker: a solid background bar with right-to-left scrolling text.
    # The text itself is read from a UTF-8 file to avoid filter escaping issues.
    speed = announcement["speed"]
    fontsize = announcement["font_size"]
    bg = announcement["bg"]
    fg = announcement["fg"]

    return (
        f"drawbox=x=0:y=h-90:w=w:h=90:color={bg}@0.92:t=fill,"
        f"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:"
        f"textfile={ANNOUNCEMENT_TEXT_FILE}:reload=0:"
        f"fontsize={fontsize}:fontcolor={fg}:"
        f"x=w-mod(t*{speed}*(tw+w),tw+w):y=h-th-28:"
        f"box=0:fix_bounds=1[{video_label}]"
    )


def ffmpeg_command(source, folder):
    out = folder / "stream.m3u8"
    seg = folder / "seg%06d.ts"
    common = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-y"]

    typ = str(source.get("type", "iptv")).lower().strip()

    if typ == "videos":
        items = source.get("items", [])
        concat, count = make_concat_file(folder, items)
        log(f"Video playlist prepared: {count} item(s)")
        if count == 0:
            raise RuntimeError("لا توجد فيديوهات صالحة في Playlist")
        input_args = [
            "-re", "-stream_loop", "-1",
            "-f", "concat", "-safe", "0", "-i", str(concat)
        ]
    elif typ == "youtube":
        # YouTube URLs are resolved by youtube_runner.py before they reach this engine.
        url = str(source.get("resolved_url", source.get("url", ""))).strip()
        if not url:
            raise RuntimeError("رابط YouTube فارغ أو لم يتم حله")
        input_args = universal_input_args({"type":"iptv","url":url})
    else:
        input_args = universal_input_args(source)

    # If source has no video stream (radio/audio), generate a black video so the
    # HLS TV channel remains a valid video stream while preserving audio.
    audio_only = typ in ("radio","mp3","aac","audio")
    logo_path = str(LOGO_FILE if LOGO_FILE.exists() else Path("/app/hichrawi-logo-crop.png"))
    announcement = read_announcement()

    if audio_only:
        # Replace absent video with a generated black canvas.
        video_chain = "[0:v][logo]overlay=W-w-30:30"
        if announcement.get("enabled"):
            video_chain += ",drawbox=x=0:y=h-90:w=w:h=90:color=" + announcement["bg"] + "@0.92:t=fill"
            video_chain += ",drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
            video_chain += f":textfile={ANNOUNCEMENT_TEXT_FILE}:reload=0:fontsize={announcement['font_size']}:fontcolor={announcement['fg']}"
            video_chain += f":x=w-mod(t*{announcement['speed']}*(tw+w),tw+w):y=h-th-28:box=0:fix_bounds=1[v]"
        else:
            video_chain += "[v]"

        filter_args = [
            "-f","lavfi","-i","color=c=black:s=1280x720:r=25",
            "-i",logo_path,
            "-filter_complex",
            "[1:v]scale=180:-1[logo];" + video_chain
        ]
        maps = ["-map","[v]","-map","0:a:0?"]
    else:
        # Preserve the existing logo overlay when no announcement is active.
        if announcement.get("enabled"):
            video_chain = "[0:v][logo]overlay=W-w-30:30"
            video_chain += ",drawbox=x=0:y=h-90:w=w:h=90:color=" + announcement["bg"] + "@0.92:t=fill"
            video_chain += ",drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
            video_chain += f":textfile={ANNOUNCEMENT_TEXT_FILE}:reload=0:fontsize={announcement['font_size']}:fontcolor={announcement['fg']}"
            video_chain += f":x=w-mod(t*{announcement['speed']}*(tw+w),tw+w):y=h-th-28:box=0:fix_bounds=1[v]"
            filter_args = [
                "-i", logo_path,
                "-filter_complex",
                "[1:v]scale=180:-1[logo];" + video_chain
            ]
            maps = ["-map","[v]","-map","0:a?"]
        else:
            filter_args = [
                "-i", logo_path,
                "-filter_complex",
                "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30"
            ]
            maps = ["-map","0:v:0","-map","0:a?"]

    return common + input_args + filter_args + maps + [
        "-c:v","libx264","-preset","veryfast",
        "-c:a","aac","-b:a","128k",
        "-f","hls",
        "-hls_time","6",
        "-hls_list_size","15",
        "-hls_flags","delete_segments+append_list",
        "-hls_segment_filename",str(seg),
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
        requested_source_name=source.get("name", ""),
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

def read_schedule():
    data = read_json(SCHEDULE_FILE, {})
    if not isinstance(data, dict):
        return {"enabled": False, "timezone_offset_minutes": 0, "items": []}
    items = data.get("items", [])
    if not isinstance(items, list):
        items = []
    return {
        "enabled": bool(data.get("enabled", True)),
        "timezone_offset_minutes": int(data.get("timezone_offset_minutes", 0) or 0),
        "items": items
    }

def schedule_target(schedule):
    """Return the latest scheduled item at or before local HH:MM for today.
    A daily schedule is assumed. Only entries with a valid source payload are used.
    """
    if not schedule.get("enabled") or not schedule.get("items"):
        return None
    offset = schedule.get("timezone_offset_minutes", 0)
    now = time.time() + offset * 60
    lt = time.gmtime(now)
    current_minutes = lt.tm_hour * 60 + lt.tm_min
    candidates = []
    for item in schedule["items"]:
        try:
            hh, mm = str(item.get("time", "")).split(":", 1)
            mins = int(hh) * 60 + int(mm)
        except Exception:
            continue
        source = item.get("source")
        if not isinstance(source, dict) or not source.get("type"):
            continue
        if mins <= current_minutes:
            candidates.append((mins, item))
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0])
    return candidates[-1][1]

def check_schedule(source):
    global last_schedule_key
    schedule = read_schedule()
    target = schedule_target(schedule)
    if not target:
        return source
    key = f'{target.get("time","")}|{target.get("sourceId","")}|{target.get("source",{}).get("name","")}'
    if key == last_schedule_key:
        return source
    target_source = dict(target.get("source") or {})
    target_source.setdefault("name", target.get("name", "Scheduled source"))
    log("SCHEDULE: due source " + str(target_source.get("name", "")))
    if (target_source.get("name") == source.get("name") and
        target_source.get("type") == source.get("type") and
        target_source.get("url", "") == source.get("url", "") and
        target_source.get("items", []) == source.get("items", [])):
        last_schedule_key = key
        return source
    ok = switch_to(target_source)
    if ok:
        last_schedule_key = key
        return target_source
    return source

def main():
    global request_mtime, schedule_mtime, last_schedule_key, announcement_mtime
    logo_request_mtime = 0
    announcement_mtime = 0

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
        # Automatic failover: if the active source dies, try the configured
        # fallback first. If fallback is unavailable, retry the current source.
        if active_proc is None or active_proc.poll() is not None:
            log("Active source stopped. Checking automatic fallback.")
            fallback = read_json(FALLBACK_FILE, {})
            same_as_source = (
                fallback.get("name", "") == source.get("name", "") and
                fallback.get("type", "") == source.get("type", "") and
                fallback.get("url", "") == source.get("url", "") and
                fallback.get("items", []) == source.get("items", [])
            ) if fallback else False
            if same_as_source:
                log("Configured fallback is the same as the failed source; skipping it.")
                fallback = {}
            if fallback and fallback.get("type") not in (None, "", "stop"):
                fallback_name = fallback.get("name", "المصدر الاحتياطي")
                write_state(
                    "failover",
                    source_type=fallback.get("type","iptv"),
                    source_name=fallback_name,
                    failover=True,
                    message="المصدر الحالي توقف — جاري تشغيل المصدر الاحتياطي..."
                )
                proc = start_candidate(fallback, STREAM_ROOT / active_dir)
                if proc:
                    active_proc = proc
                    source = fallback
                    write_state(
                        "running",
                        source_type=source.get("type","iptv"),
                        source_name=source.get("name",""),
                        failover=True,
                        message="تم تشغيل المصدر الاحتياطي تلقائياً."
                    )
                    log("Automatic failover succeeded: " + fallback_name)
                else:
                    log("Fallback failed. Retrying current source.")
                    proc = start_candidate(source, STREAM_ROOT / active_dir)
                    if proc:
                        active_proc = proc
                        write_state("running", source_type=source.get("type","iptv"), source_name=source.get("name",""))
                    else:
                        active_proc = None
                        write_state("waiting")
                        time.sleep(5)
                        continue
            else:
                log("No fallback configured. Rebuilding current source automatically.")
                proc = start_candidate(source, STREAM_ROOT / active_dir)
                if proc:
                    active_proc = proc
                    write_state("running", source_type=source.get("type","iptv"), source_name=source.get("name",""))
                else:
                    active_proc = None
                    write_state("waiting")
                    time.sleep(5)
                    continue

        # Daily server-side schedule. It runs independently of the admin PC.
        try:
            smt = SCHEDULE_FILE.stat().st_mtime
        except FileNotFoundError:
            smt = 0
        if smt != schedule_mtime:
            schedule_mtime = smt
            # Allow a changed schedule to be evaluated immediately.
            last_schedule_key = ""
        scheduled_source = check_schedule(source)
        if scheduled_source is not source:
            source = scheduled_source

        # Watch logo changes. Prepare a new HLS candidate with the new logo,
        # then switch safely so the current stream is not cut before readiness.
        try:
            lmt = LOGO_REQUEST_FILE.stat().st_mtime
        except FileNotFoundError:
            lmt = 0
        if lmt and lmt != logo_request_mtime:
            logo_request_mtime = lmt
            if source and source.get("type") not in (None, "", "stop"):
                log("LOGO CHANGE DETECTED: applying new logo safely.")
                if switch_to(source):
                    log("LOGO CHANGE APPLIED.")
                else:
                    log("LOGO CHANGE FAILED; keeping current stream.")

        # Watch announcement changes. Prepare a new HLS candidate with the
        # current source so the advertisement is applied safely without
        # changing the selected source.
        try:
            amt = ANNOUNCEMENT_FILE.stat().st_mtime
        except FileNotFoundError:
            amt = 0

        if amt and amt != announcement_mtime:
            announcement_mtime = amt
            announcement = read_announcement()
            log(
                "ANNOUNCEMENT CHANGE DETECTED: "
                + ("enabled" if announcement.get("enabled") else "disabled")
            )
            if source and source.get("type") not in (None, "", "stop"):
                if switch_to(source):
                    log("ANNOUNCEMENT CHANGE APPLIED.")
                else:
                    log("ANNOUNCEMENT CHANGE FAILED; keeping current stream.")

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