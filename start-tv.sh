#!/bin/bash

set -u

SOURCE_FILE="/app/source.json"
REQUEST_FILE="/app/source_request.json"
STATE_FILE="/app/stream_state.json"
LOG_FILE="/tmp/tv.log"

ANNOUNCEMENT_FILE="/stream/announcement.json"
ANNOUNCEMENT_TEXT_FILE="/stream/announcement.txt"
ANNOUNCEMENT_SIGNATURE=""
ANNOUNCEMENT_ENABLED="false"

STREAM_ROOT="/stream"

ACTIVE_SLOT="a"
ACTIVE_SOURCE=""
ACTIVE_NAME=""

CURRENT_PID=""

resolve_local_source() {
    local value="$1"

    if [[ "$value" == /videos/* ]]; then
        printf '/app%s\n' "$value"
    else
        printf '%s\n' "$value"
    fi
}

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

announcement_font() {
    if [ -f "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf" ]; then
        printf '%s\n' "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"
    elif [ -f "/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf" ]; then
        printf '%s\n' "/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf"
    else
        printf '%s\n' "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    fi
}

load_announcement() {
    if [ ! -f "$ANNOUNCEMENT_FILE" ]; then
        ANNOUNCEMENT_ENABLED="false"
        ANNOUNCEMENT_SIGNATURE=""
        return
    fi

    ANNOUNCEMENT_SIGNATURE="$(sha256sum "$ANNOUNCEMENT_FILE" 2>/dev/null | awk '{print $1}')"

    ANNOUNCEMENT_DATA="$(python3 -c '
import json,sys
from pathlib import Path

p=Path(sys.argv[1])

try:
    d=json.loads(p.read_text(encoding="utf-8"))
except Exception:
    d={}

enabled=bool(d.get("enabled",False))
text=str(d.get("text","") or "").strip()

try:
    speed=float(d.get("speed",3) or 3)
except Exception:
    speed=3

try:
    size=int(float(str(d.get("fontSize",20) or 20).strip().lower().replace("px","")))
except Exception:
    size=20

bg=str(d.get("bgColor",d.get("backgroundColor","#e00000")) or "#e00000").lstrip("#")
fg=str(d.get("textColor",d.get("color","#ffffff")) or "#ffffff").lstrip("#")

speed=max(0.2,min(speed,20))
size=max(18,min(size,80))

if len(bg)!=6:
    bg="e00000"

if len(fg)!=6:
    fg="ffffff"

print(
    ("true" if enabled and text else "false")
    + "\t" + text.replace("\t"," ")
    + "\t" + str(speed)
    + "\t" + str(size)
    + "\t0x" + bg
    + "\t0x" + fg
)
' "$ANNOUNCEMENT_FILE")"

    IFS=$'\t' read -r \
        ANNOUNCEMENT_ENABLED \
        ANNOUNCEMENT_TEXT \
        ANNOUNCEMENT_SPEED \
        ANNOUNCEMENT_SIZE \
        ANNOUNCEMENT_BG \
        ANNOUNCEMENT_FG <<< "$ANNOUNCEMENT_DATA"

    if [ "$ANNOUNCEMENT_ENABLED" = "true" ]; then
        printf '%s' "$ANNOUNCEMENT_TEXT" > "$ANNOUNCEMENT_TEXT_FILE"

        log "ANNOUNCEMENT: enabled text='$ANNOUNCEMENT_TEXT' speed=$ANNOUNCEMENT_SPEED size=$ANNOUNCEMENT_SIZE"
    else
        rm -f "$ANNOUNCEMENT_TEXT_FILE"
        log "ANNOUNCEMENT: disabled"
    fi
}

# ============================================================
# YOUTUBE RESOLVER
# ============================================================

resolve_youtube_source() {
    local source="$1"

    if [[ "$source" == *"youtube.com/"* || "$source" == *"youtu.be/"* ]]; then

        log "YOUTUBE: Resolving direct stream URL..."

        local direct_url

        direct_url="$(python3 /app/youtube_runner.py "$source" 2>>"$LOG_FILE")"

        if [ -z "$direct_url" ]; then
            log "YOUTUBE: Failed to resolve direct stream URL."
            return 1
        fi

        log "YOUTUBE: Direct stream URL resolved."

        printf '%s\n' "$direct_url"
        return 0
    fi

    printf '%s\n' "$source"
}

start_ffmpeg() {
    local source="$1"
    local slot="$2"

    # YouTube: resolve الرابط قبل تشغيل FFmpeg
    if [[ "$source" == *"youtube.com/"* || "$source" == *"youtu.be/"* ]]; then

        log "YOUTUBE: Source detected."

        source="$(resolve_youtube_source "$source")" || {
            log "YOUTUBE: Could not resolve source."
            return 1
        }
    fi

    local playlist="$STREAM_ROOT/source_${slot}.m3u8"
    local segment="$STREAM_ROOT/${slot}_%06d.ts"
    local ffmpeg_log="$STREAM_ROOT/ffmpeg_${slot}.log"

    cleanup_slot "$slot"

    log "Starting FFmpeg in slot $slot: $source"

    load_announcement

    local font
    local filter

    font="$(announcement_font)"

    if [ "$ANNOUNCEMENT_ENABLED" = "true" ]; then

        filter="[1:v]scale=180:-1[logo];"
        filter+="[0:v][logo]overlay=W-w-30:30[base];"
        filter+="[base]drawbox=x=0:y=h-70:w=iw:h=70:color=${ANNOUNCEMENT_BG}@0.92:t=fill[bar];"
        filter+="[bar]drawtext=fontfile=${font}:textfile=${ANNOUNCEMENT_TEXT_FILE}:reload=1:"
        filter+="fontsize=${ANNOUNCEMENT_SIZE}:fontcolor=${ANNOUNCEMENT_FG}:"
        filter+="x=w-mod(t*${ANNOUNCEMENT_SPEED}*(tw+w),tw+w):"
        filter+="y=h-th-22:"
        filter+="format=yuv420p[outv]"

        log "ANNOUNCEMENT FILTER ACTIVE."

    else

        filter="[1:v]scale=180:-1[logo];"
        filter+="[0:v][logo]overlay=W-w-30:30,"
        filter+="format=yuv420p[outv]"

    fi

    ffmpeg \
        -hide_banner \
        -loglevel verbose \
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
        -filter_complex "$filter" \
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
        > "$ffmpeg_log" 2>&1 &

    FFMPEG_PID=$!

    echo "[TV] FFmpeg PID: $FFMPEG_PID" >> "$ffmpeg_log"

    log "FFmpeg slot $slot PID=$FFMPEG_PID log=$ffmpeg_log"
}

wait_ready() {
    local slot="$1"
    local pid="$2"

    local playlist="$STREAM_ROOT/source_${slot}.m3u8"
    local count

    for i in $(seq 1 60); do

        if ! kill -0 "$pid" 2>/dev/null; then

            log "FFmpeg slot $slot stopped before ready."

            debug_log="$STREAM_ROOT/ffmpeg_${slot}.log"

            if [ -f "$debug_log" ]; then
                log "========== FFmpeg slot $slot ERROR =========="

                tail -n 120 "$debug_log" |
                while IFS= read -r line; do
                    log "FFMPEG-$slot: $line"
                done

                log "========== END FFmpeg slot $slot ERROR =========="
            fi

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
    local temp_link="$STREAM_ROOT/stream.m3u8.switch"

    if [ ! -s "$source_playlist" ]; then
        return 1
    fi

    rm -f "$temp_link"

    ln -s "$source_playlist" "$temp_link" || return 1

    mv -Tf "$temp_link" "$public_playlist" || return 1

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

    requested_source=$(python3 - "$REQUEST_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)

    source = str(
        data.get("url")
        or data.get("source")
        or ""
    ).strip()

    if not source:
        items = data.get("items") or []

        if isinstance(items, list):
            for item in items:

                if isinstance(item, dict):
                    item = (
                        item.get("url")
                        or item.get("source")
                        or ""
                    )

                if str(item or "").strip():
                    source = str(item).strip()
                    break

    if source.startswith("/videos/"):
        source = "/app" + source

    print(source)

except Exception:
    print("")
PY
)

    requested_source=$(resolve_local_source "$requested_source")

    if [ -z "$requested_source" ]; then

        log "SOURCE REQUEST: missing URL/source/items."

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

    if ! start_ffmpeg "$requested_source" "$new_slot"; then

        log "SOURCE: FFmpeg could not start."

        write_state \
            "active" \
            "$ACTIVE_SOURCE" \
            "$ACTIVE_NAME" \
            "$ACTIVE_SLOT" \
            "New source could not start"

        rm -f "$REQUEST_FILE"

        return
    fi

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

    sleep 8

    log "Stopping old FFmpeg PID: $old_pid"

    stop_pid "$old_pid"

    cleanup_slot "$old_slot"

    log "Old source stopped."
}

apply_announcement_change() {

    local new_slot
    local old_slot
    local old_pid
    local new_pid

    if [ "$ACTIVE_SLOT" = "a" ]; then
        new_slot="b"
    else
        new_slot="a"
    fi

    old_slot="$ACTIVE_SLOT"
    old_pid="$CURRENT_PID"

    log "========================================"
    log "ANNOUNCEMENT CHANGE REQUEST"
    log "========================================"

    write_state \
        "testing" \
        "$ACTIVE_SOURCE" \
        "$ACTIVE_NAME" \
        "$ACTIVE_SLOT" \
        "Applying announcement"

    if ! start_ffmpeg "$ACTIVE_SOURCE" "$new_slot"; then

        log "ANNOUNCEMENT: FFmpeg could not start."

        return
    fi

    new_pid="$FFMPEG_PID"

    if ! wait_ready "$new_slot" "$new_pid"; then

        log "ANNOUNCEMENT: new stream failed readiness; keeping current stream."

        debug_log="$STREAM_ROOT/ffmpeg_${new_slot}.log"

        if [ -f "$debug_log" ]; then

            log "ANNOUNCEMENT: FFmpeg diagnostics:"

            tail -n 100 "$debug_log" |
            while IFS= read -r line; do
                log "FFMPEG-${new_slot}: $line"
            done
        fi

        stop_pid "$new_pid"
        cleanup_slot "$new_slot"

        write_state \
            "active" \
            "$ACTIVE_SOURCE" \
            "$ACTIVE_NAME" \
            "$ACTIVE_SLOT" \
            "Announcement update failed; current stream kept"

        return
    fi

    if ! publish_playlist "$new_slot"; then

        log "ANNOUNCEMENT: failed to publish new playlist; keeping current stream."

        stop_pid "$new_pid"
        cleanup_slot "$new_slot"

        return
    fi

    ACTIVE_SLOT="$new_slot"
    CURRENT_PID="$new_pid"

    write_state \
        "active" \
        "$ACTIVE_SOURCE" \
        "$ACTIVE_NAME" \
        "$ACTIVE_SLOT" \
        "Announcement applied"

    log "ANNOUNCEMENT CHANGE APPLIED."

    sleep 8

    stop_pid "$old_pid"

    cleanup_slot "$old_slot"

    log "Old announcement stream stopped."
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

rm -f \
    "$STREAM_ROOT/stream.m3u8" \
    "$STREAM_ROOT/stream.m3u8.switch"

load_main_source

log "Main source: $ACTIVE_SOURCE"

write_state \
    "starting" \
    "$ACTIVE_SOURCE" \
    "$ACTIVE_NAME" \
    "$ACTIVE_SLOT" \
    "Starting main source"

if start_ffmpeg "$ACTIVE_SOURCE" "$ACTIVE_SLOT"; then

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

else

    log "Main source could not start."

    CURRENT_PID=""

    sleep 5
fi

# ============================================================
# MAIN LOOP
# ============================================================

load_announcement

ANNOUNCEMENT_SIGNATURE="${ANNOUNCEMENT_SIGNATURE:-}"

while true
do

    # --------------------------------------------------------
    # FFmpeg died
    # --------------------------------------------------------

    if [ -z "$CURRENT_PID" ] || ! kill -0 "$CURRENT_PID" 2>/dev/null; then

        log "Active FFmpeg stopped."

        write_state \
            "restarting" \
            "$ACTIVE_SOURCE" \
            "$ACTIVE_NAME" \
            "$ACTIVE_SLOT" \
            "Restarting active source"

        if start_ffmpeg "$ACTIVE_SOURCE" "$ACTIVE_SLOT"; then

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

        else

            CURRENT_PID=""

            sleep 5

            continue
        fi
    fi

    # --------------------------------------------------------
    # Announcement
    # --------------------------------------------------------

    if [ -f "$ANNOUNCEMENT_FILE" ]; then

        NEW_ANNOUNCEMENT_SIGNATURE="$(
            sha256sum "$ANNOUNCEMENT_FILE" 2>/dev/null |
            awk '{print $1}'
        )"

        if [ -n "$NEW_ANNOUNCEMENT_SIGNATURE" ] &&
           [ "$NEW_ANNOUNCEMENT_SIGNATURE" != "$ANNOUNCEMENT_SIGNATURE" ]; then

            log "ANNOUNCEMENT CHANGE DETECTED."

            ANNOUNCEMENT_SIGNATURE="$NEW_ANNOUNCEMENT_SIGNATURE"

            apply_announcement_change
        fi
    fi

    # --------------------------------------------------------
    # Source request
    # --------------------------------------------------------

    if [ -f "$REQUEST_FILE" ]; then
        switch_source
    fi

    sleep 1
done
