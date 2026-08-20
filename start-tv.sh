#!/bin/bash

set -u

SOURCE_FILE="/app/source.json"
REQUEST_FILE="/app/source_request.json"
STATE_FILE="/app/stream_state.json"
LOG_FILE="/tmp/tv.log"

STREAM_ROOT="/stream"

ACTIVE_SLOT="a"
ACTIVE_SOURCE=""
ACTIVE_NAME=""

CURRENT_PID=""

log() {
    echo "[TV] $*" | tee -a "$LOG_FILE"
}

get_json_value() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)

    value = data.get(sys.argv[2], "")
    print(value if value is not None else "")
except Exception:
    print("")
PY
}

write_state() {
    local status="$1"
    local source="$2"
    local name="$3"
    local slot="$4"
    local message="${5:-}"

    python3 - "$STATE_FILE" "$status" "$source" "$name" "$slot" "$message" <<'PY'
import json
import sys
import time
from pathlib import Path

p = Path(sys.argv[1])

data = {
    "status": sys.argv[2],
    "active_source": sys.argv[3],
    "active_name": sys.argv[4],
    "active_dir": "source_" + sys.argv[5],
    "message": sys.argv[6],
    "updated_at": time.time()
}

tmp = p.with_suffix(".tmp")
tmp.write_text(
    json.dumps(data, ensure_ascii=False),
    encoding="utf-8"
)
tmp.replace(p)
PY
}

cleanup_slot() {
    local slot="$1"

    rm -f \
        "$STREAM_ROOT/source_${slot}.m3u8" \
        "$STREAM_ROOT/${slot}_"*.ts \
        "$STREAM_ROOT/${slot}_"*.tmp
}

stop_pid() {
    local pid="${1:-}"

    if [ -z "$pid" ]; then
        return
    fi

    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        return
    fi

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true

        for i in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                return
            fi
            sleep 1
        done

        kill -9 "$pid" 2>/dev/null || true
    fi
}

start_ffmpeg() {
    local source="$1"
    local slot="$2"

    local playlist="$STREAM_ROOT/source_${slot}.m3u8"
    local segment="$STREAM_ROOT/${slot}_%06d.ts"

    cleanup_slot "$slot"

    log "Starting FFmpeg in slot $slot: $source"

    ffmpeg \
        -hide_banner \
        -loglevel info \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_at_eof 1 \
        -reconnect_delay_max 10 \
        -rw_timeout 15000000 \
        -fflags +genpts+discardcorrupt \
        -thread_queue_size 2048 \
        -i "$source" \
        -loop 1 \
        -framerate 25 \
        -thread_queue_size 64 \
        -i "/app/hichrawi-logo-crop.png" \
        -filter_complex \
        "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30,format=yuv420p[outv]" \
        -map "[outv]" \
        -map 0:a:0? \
        -c:v libx264 \
        -preset superfast \
        -tune zerolatency \
        -profile:v main \
        -level:v 3.1 \
        -pix_fmt yuv420p \
        -r 25 \
        -crf 24 \
        -g 100 \
        -keyint_min 100 \
        -sc_threshold 0 \
        -force_key_frames "expr:gte(t,n_forced*4)" \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -af "aresample=async=1:first_pts=0" \
        -f hls \
        -hls_time 4 \
        -hls_list_size 10 \
        -hls_delete_threshold 5 \
        -hls_flags delete_segments+independent_segments+omit_endlist \
        -hls_segment_type mpegts \
        -hls_allow_cache 0 \
        -hls_segment_filename "$segment" \
        "$playlist" \
        >> "$LOG_FILE" 2>&1 &

    FFMPEG_PID=$!

    echo "[TV] FFmpeg PID: $FFMPEG_PID" >> "$LOG_FILE"
}

wait_ready() {
    local slot="$1"
    local pid="$2"

    local playlist="$STREAM_ROOT/source_${slot}.m3u8"
    local count

    for i in $(seq 1 60); do

        if ! kill -0 "$pid" 2>/dev/null; then
            log "FFmpeg slot $slot stopped before ready."
            return 1
        fi

        if [ -f "$playlist" ]; then

            count=$(grep -c '^#EXTINF:' "$playlist" 2>/dev/null || true)

            if [ "${count:-0}" -ge 3 ]; then
                log "Slot $slot READY with $count segments."
                return 0
            fi
        fi

        sleep 1
    done

    log "Slot $slot did not become ready."

    return 1
}

publish_playlist() {
    local slot="$1"

    local source_playlist="$STREAM_ROOT/source_${slot}.m3u8"
    local public_playlist="$STREAM_ROOT/stream.m3u8"
    local temp_playlist="$STREAM_ROOT/stream.m3u8.switch"

    if [ ! -s "$source_playlist" ]; then
        return 1
    fi

    cp "$source_playlist" "$temp_playlist" || return 1

    mv -f "$temp_playlist" "$public_playlist" || return 1

    return 0
}

load_main_source() {
    ACTIVE_SOURCE=$(get_json_value "$SOURCE_FILE" "url")

    if [ -z "$ACTIVE_SOURCE" ]; then
        ACTIVE_SOURCE="/app/videos/videos/1.mp4"
    fi

    ACTIVE_NAME=$(get_json_value "$SOURCE_FILE" "name")

    if [ -z "$ACTIVE_NAME" ]; then
        ACTIVE_NAME="المصدر الرئيسي"
    fi
}

save_active_source() {
    python3 - "$SOURCE_FILE" "$ACTIVE_SOURCE" "$ACTIVE_NAME" <<'PY'
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])

try:
    data = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    data = {}

data["url"] = sys.argv[2]
data["name"] = sys.argv[3]

tmp = p.with_suffix(".tmp")

tmp.write_text(
    json.dumps(data, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

tmp.replace(p)
PY
}

switch_source() {

    local requested_source
    local requested_name
    local new_slot
    local old_slot
    local old_pid
    local new_pid

    requested_source=$(get_json_value "$REQUEST_FILE" "url")

    if [ -z "$requested_source" ]; then
        requested_source=$(get_json_value "$REQUEST_FILE" "source")
    fi

    if [ -z "$requested_source" ]; then
        log "SOURCE REQUEST: missing URL."
        rm -f "$REQUEST_FILE"
        return
    fi

    requested_name=$(get_json_value "$REQUEST_FILE" "name")

    if [ -z "$requested_name" ]; then
        requested_name="مصدر جديد"
    fi

    if [ "$requested_source" = "$ACTIVE_SOURCE" ]; then
        log "SOURCE REQUEST: source already active."
        rm -f "$REQUEST_FILE"
        return
    fi

    if [ "$ACTIVE_SLOT" = "a" ]; then
        new_slot="b"
    else
        new_slot="a"
    fi

    old_slot="$ACTIVE_SLOT"
    old_pid="$CURRENT_PID"

    log "========================================"
    log "SOURCE SWITCH REQUEST"
    log "Current: $ACTIVE_SOURCE"
    log "New:     $requested_source"
    log "========================================"

    write_state \
        "testing" \
        "$ACTIVE_SOURCE" \
        "$ACTIVE_NAME" \
        "$ACTIVE_SLOT" \
        "Testing new source"

    start_ffmpeg "$requested_source" "$new_slot"

    new_pid="$FFMPEG_PID"

    if ! wait_ready "$new_slot" "$new_pid"; then

        log "NEW SOURCE FAILED."
        log "Keeping current source."

        stop_pid "$new_pid"
        cleanup_slot "$new_slot"

        write_state \
            "active" \
            "$ACTIVE_SOURCE" \
            "$ACTIVE_NAME" \
            "$ACTIVE_SLOT" \
            "New source failed; current source kept"

        rm -f "$REQUEST_FILE"

        return
    fi

    log "NEW SOURCE READY."

    write_state \
        "switching" \
        "$ACTIVE_SOURCE" \
        "$ACTIVE_NAME" \
        "$ACTIVE_SLOT" \
        "New source ready"

    if ! publish_playlist "$new_slot"; then

        log "FAILED TO PUBLISH NEW PLAYLIST."

        stop_pid "$new_pid"
        cleanup_slot "$new_slot"

        write_state \
            "active" \
            "$ACTIVE_SOURCE" \
            "$ACTIVE_NAME" \
            "$ACTIVE_SLOT" \
            "Playlist publish failed"

        rm -f "$REQUEST_FILE"

        return
    fi

    # التبديل تم بنجاح.
    ACTIVE_SOURCE="$requested_source"
    ACTIVE_NAME="$requested_name"
    ACTIVE_SLOT="$new_slot"
    CURRENT_PID="$new_pid"

    save_active_source

    write_state \
        "active" \
        "$ACTIVE_SOURCE" \
        "$ACTIVE_NAME" \
        "$ACTIVE_SLOT" \
        "Source switched successfully"

    log "========================================"
    log "SOURCE SWITCH SUCCESS"
    log "Active source: $ACTIVE_SOURCE"
    log "Active slot: $ACTIVE_SLOT"
    log "========================================"

    rm -f "$REQUEST_FILE"

    # نخلي المصدر الجديد يخدم شوية قبل إيقاف القديم.
    sleep 8

    log "Stopping old FFmpeg PID: $old_pid"

    stop_pid "$old_pid"

    cleanup_slot "$old_slot"

    log "Old source stopped."
}

# ============================================================
# START
# ============================================================

mkdir -p "$STREAM_ROOT"

touch "$LOG_FILE"

log "========================================"
log "HICHRAWI-TV starting..."
log "========================================"

cleanup_slot "a"
cleanup_slot "b"

load_main_source

log "Main source: $ACTIVE_SOURCE"

write_state \
    "starting" \
    "$ACTIVE_SOURCE" \
    "$ACTIVE_NAME" \
    "$ACTIVE_SLOT" \
    "Starting main source"

start_ffmpeg "$ACTIVE_SOURCE" "$ACTIVE_SLOT"

CURRENT_PID="$FFMPEG_PID"

if wait_ready "$ACTIVE_SLOT" "$CURRENT_PID"; then

    publish_playlist "$ACTIVE_SLOT"

    write_state \
        "active" \
        "$ACTIVE_SOURCE" \
        "$ACTIVE_NAME" \
        "$ACTIVE_SLOT" \
        "HICHRAWI-TV LIVE"

    log "HICHRAWI-TV LIVE."

else

    log "Main source failed to become ready."

    stop_pid "$CURRENT_PID"

    CURRENT_PID=""

    sleep 5
fi

# ============================================================
# MAIN LOOP
# ============================================================

while true
do

    # --------------------------------------------------------
    # إذا FFmpeg الحالي مات
    # --------------------------------------------------------

    if [ -z "$CURRENT_PID" ] || ! kill -0 "$CURRENT_PID" 2>/dev/null; then

        log "Active FFmpeg stopped."

        write_state \
            "restarting" \
            "$ACTIVE_SOURCE" \
            "$ACTIVE_NAME" \
            "$ACTIVE_SLOT" \
            "Restarting active source"

        start_ffmpeg "$ACTIVE_SOURCE" "$ACTIVE_SLOT"

        CURRENT_PID="$FFMPEG_PID"

        if wait_ready "$ACTIVE_SLOT" "$CURRENT_PID"; then

            publish_playlist "$ACTIVE_SLOT"

            write_state \
                "active" \
                "$ACTIVE_SOURCE" \
                "$ACTIVE_NAME" \
                "$ACTIVE_SLOT" \
                "Stream active"

            log "HICHRAWI-TV LIVE."

        else

            log "Current source could not be recovered."

            stop_pid "$CURRENT_PID"

            CURRENT_PID=""

            sleep 5
            continue
        fi
    fi

    # --------------------------------------------------------
    # طلب تبديل مصدر
    # --------------------------------------------------------

    if [ -f "$REQUEST_FILE" ]; then
        switch_source
    fi

    sleep 1
done
