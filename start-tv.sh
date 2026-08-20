#!/bin/bash

set -u

STREAM="/stream"
SOURCE_FILE="/app/source.json"
REQUEST_FILE="/app/source_request.json"
FALLBACK_FILE="/stream/fallback_source.json"
STATE_FILE="/app/stream_state.json"
LOG_FILE="/tmp/tv.log"
LOGO="/app/hichrawi-logo-crop.png"

PREPARE_TIMEOUT=180
GRACE_SECONDS=45
CHECK_SECONDS=3

mkdir -p "$STREAM"

log() {
    echo "[TV] $*" | tee -a "$LOG_FILE"
}

write_state() {
    local status="$1"
    local name="${2:-}"
    local type="${3:-iptv}"
    local message="${4:-}"

    python3 - "$status" "$name" "$type" "$message" <<'PY'
import json
import sys
from pathlib import Path
import time

path = Path("/app/stream_state.json")

data = {
    "status": sys.argv[1],
    "source_name": sys.argv[2],
    "source_type": sys.argv[3],
    "message": sys.argv[4],
    "updated_at": time.time()
}

tmp = path.with_suffix(".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
tmp.replace(path)
PY
}

read_json_value() {
    local file="$1"
    local key="$2"

    python3 - "$file" "$key" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    value = data.get(sys.argv[2], "")
    print(value if value is not None else "")
except Exception:
    print("")
PY
}

read_source_json() {
    SOURCE_URL=$(read_json_value "$SOURCE_FILE" "url")
    SOURCE_TYPE=$(read_json_value "$SOURCE_FILE" "type")

    [ -z "$SOURCE_TYPE" ] && SOURCE_TYPE="iptv"
    [ -z "$SOURCE_URL" ] && SOURCE_URL=""
}

source_name_from_file() {
    local file="$1"

    python3 - "$file" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print(data.get("name", "") or "")
except Exception:
    print("")
PY
}

source_type_from_file() {
    local file="$1"

    python3 - "$file" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print(data.get("type", "iptv") or "iptv")
except Exception:
    print("iptv")
PY
}

source_url_from_file() {
    local file="$1"

    python3 - "$file" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print(data.get("url", "") or "")
except Exception:
    print("")
PY
}

build_ffmpeg() {
    local url="$1"
    local workdir="$2"
    local prefix="$3"

    mkdir -p "$workdir"

    local playlist="$workdir/stream.m3u8"
    local segments="$STREAM/${prefix}_%06d.ts"

    rm -f "$playlist" "$workdir"/*.tmp

    log "Preparing source: $url"

    ffmpeg \
        -hide_banner \
        -loglevel info \
        -y \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_at_eof 1 \
        -reconnect_delay_max 10 \
        -rw_timeout 15000000 \
        -fflags +genpts+discardcorrupt \
        -thread_queue_size 2048 \
        -i "$url" \
        -loop 1 \
        -framerate 25 \
        -thread_queue_size 64 \
        -i "$LOGO" \
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
        -hls_segment_filename "$segments" \
        "$playlist" \
        >>/tmp/tv-ffmpeg.log 2>&1 &

    echo $!
}

playlist_ready() {
    local playlist="$1"

    [ -f "$playlist" ] || return 1
    [ "$(stat -c%s "$playlist" 2>/dev/null || echo 0)" -gt 100 ] || return 1

    grep -q "#EXTINF" "$playlist" 2>/dev/null || return 1

    local count
    count=$(grep -c '\.ts$' "$playlist" 2>/dev/null || echo 0)

    [ "$count" -ge 2 ]
}

activate_playlist() {
    local playlist="$1"

    local tmp="$STREAM/.stream.m3u8.tmp"

    rm -f "$tmp"
    ln -s "$playlist" "$tmp"
    mv -Tf "$tmp" "$STREAM/stream.m3u8"
}

stop_pid() {
    local pid="${1:-}"

    [ -z "$pid" ] && return

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 2

        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
}

cleanup_prefix() {
    local prefix="$1"

    sleep "$GRACE_SECONDS"

    rm -f "$STREAM/${prefix}"_*.ts
}

prepare_source() {
    local url="$1"
    local prefix="$2"

    local dir="$STREAM/.pipelines/$prefix"
    local playlist="$dir/stream.m3u8"

    rm -rf "$dir"
    mkdir -p "$dir"

    local pid
    pid=$(build_ffmpeg "$url" "$dir" "$prefix")

    local deadline=$(( $(date +%s) + PREPARE_TIMEOUT ))

    while [ "$(date +%s)" -lt "$deadline" ]
    do
        if ! kill -0 "$pid" 2>/dev/null; then
            log "Candidate FFmpeg stopped before becoming ready."
            echo ""
            return 1
        fi

        if playlist_ready "$playlist"; then
            echo "$pid"
            return 0
        fi

        sleep 2
    done

    log "Candidate source did not become ready within 3 minutes."

    stop_pid "$pid"

    echo ""
    return 1
}

current_pid=""
current_prefix="main"
current_name="الوطنية 1"
current_type="iptv"
current_url=""

switch_source() {
    local new_url="$1"
    local new_name="$2"
    local new_type="$3"

    [ -z "$new_url" ] && return 1

    local prefix="src_$(date +%s%N)"
    local playlist="$STREAM/.pipelines/$prefix/stream.m3u8"

    write_state "switching" "$new_name" "$new_type" "جاري تحضير المصدر الجديد..."

    log "Preparing new source: $new_name"

    local new_pid
    new_pid=$(prepare_source "$new_url" "$prefix")

    if [ -z "$new_pid" ]; then
        write_state "running" "$current_name" "$current_type" "فشل التبديل — البث الحالي مستمر."
        log "Source switch failed. Current stream remains active."
        return 1
    fi

    local old_pid="$current_pid"
    local old_prefix="$current_prefix"

    # التبديل الحقيقي هنا: playlist جديدة جاهزة قبل التبديل.
    activate_playlist "$playlist"

    current_pid="$new_pid"
    current_prefix="$prefix"
    current_name="$new_name"
    current_type="$new_type"
    current_url="$new_url"

    write_state "switched" "$current_name" "$current_type" "تم التبديل بنجاح."

    log "SOURCE SWITCHED -> $current_name"

    # نعطي المشغلات القديمة وقت باش تجيب آخر segments القديمة.
    if [ -n "$old_pid" ]; then
        (
            sleep "$GRACE_SECONDS"
            stop_pid "$old_pid"
            rm -f "$STREAM/${old_prefix}"_*.ts
            rm -rf "$STREAM/.pipelines/$old_prefix"
        ) &
    fi

    return 0
}

get_requested_source() {
    [ -f "$REQUEST_FILE" ] || return 1

    python3 "$REQUEST_FILE" <<'PY' >/dev/null 2>&1
PY

    python3 - "$REQUEST_FILE" <<'PY'
import json
import sys

try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
    url=(d.get("url") or "").strip()
    name=(d.get("name") or "").strip()
    typ=(d.get("type") or "iptv").strip()

    if url:
        print(json.dumps({
            "url":url,
            "name":name,
            "type":typ
        }, ensure_ascii=False))
    else:
        print("")
except Exception:
    print("")
PY
}

get_fallback_source() {
    [ -f "$FALLBACK_FILE" ] || return 1

    python3 - "$FALLBACK_FILE" <<'PY'
import json
import sys

try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
    if not d.get("enabled", True):
        print("")
        raise SystemExit

    url=(d.get("url") or "").strip()
    name=(d.get("name") or "").strip()
    typ=(d.get("type") or "iptv").strip()

    if url:
        print(json.dumps({
            "url":url,
            "name":name,
            "type":typ
        }, ensure_ascii=False))
    else:
        print("")
except Exception:
    print("")
PY
}

# ============================================================
# START MAIN SOURCE
# ============================================================

read_source_json

current_url="$SOURCE_URL"

[ -z "$current_url" ] && {
    log "ERROR: source.json has no URL."
    exit 1
}

current_name="الوطنية 1"
current_type="${SOURCE_TYPE:-iptv}"
current_prefix="main"

rm -rf "$STREAM/.pipelines"
mkdir -p "$STREAM/.pipelines"

rm -f "$STREAM/stream.m3u8"
rm -f "$STREAM/*.ts"
rm -f "$REQUEST_FILE"

log "Starting HICHRAWI-TV main source..."
log "Main URL: $current_url"

write_state "starting" "$current_name" "$current_type" "جاري تشغيل المصدر الرئيسي..."

current_pid=$(prepare_source "$current_url" "$current_prefix")

if [ -z "$current_pid" ]; then
    log "ERROR: Main source failed to start."
    write_state "failed" "$current_name" "$current_type" "المصدر الرئيسي فشل."
    exit 1
fi

activate_playlist "$STREAM/.pipelines/$current_prefix/stream.m3u8"

write_state "running" "$current_name" "$current_type" "البث يعمل."

log "HICHRAWI-TV is LIVE."

# ============================================================
# MAIN WATCH LOOP
# ============================================================

while true
do
    # --------------------------------------------------------
    # 1) طلب تبديل المصدر من لوحة الإدارة
    # --------------------------------------------------------

    if [ -f "$REQUEST_FILE" ]; then

        REQUEST_JSON=$(get_requested_source)

        if [ -n "$REQUEST_JSON" ]; then

            REQUEST_URL=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["url"])' "$REQUEST_JSON")
            REQUEST_NAME=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$REQUEST_JSON")
            REQUEST_TYPE=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["type"])' "$REQUEST_JSON")

            if [ -z "$REQUEST_NAME" ]; then
                REQUEST_NAME="المصدر الجديد"
            fi

            if [ "$REQUEST_URL" != "$current_url" ]; then

                log "SOURCE REQUEST DETECTED -> $REQUEST_NAME"

                if switch_source "$REQUEST_URL" "$REQUEST_NAME" "$REQUEST_TYPE"; then
                    rm -f "$REQUEST_FILE"
                fi

            else
                rm -f "$REQUEST_FILE"
            fi
        fi
    fi

    # --------------------------------------------------------
    # 2) مراقبة FFmpeg
    # --------------------------------------------------------

    if [ -z "$current_pid" ] || ! kill -0 "$current_pid" 2>/dev/null; then

        log "ACTIVE FFmpeg stopped."

        FALLBACK_JSON=$(get_fallback_source || true)

        if [ -n "$FALLBACK_JSON" ]; then

            FALLBACK_URL=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["url"])' "$FALLBACK_JSON")
            FALLBACK_NAME=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$FALLBACK_JSON")
            FALLBACK_TYPE=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["type"])' "$FALLBACK_JSON")

            log "Trying configured fallback: $FALLBACK_NAME"

            if ! switch_source "$FALLBACK_URL" "$FALLBACK_NAME" "$FALLBACK_TYPE"; then
                log "Fallback failed. Restarting current source."
                current_pid=$(prepare_source "$current_url" "$current_prefix")
            fi

        else
            log "No fallback configured. Restarting current source."
            current_pid=$(prepare_source "$current_url" "$current_prefix")
        fi
    fi

    sleep "$CHECK_SECONDS"
done
