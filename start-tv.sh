#!/bin/bash
set -u

SOURCE_FILE="/app/source.json"
REQUEST_FILE="/app/source_request.json"
STATE_FILE="/app/stream_state.json"
LOG_FILE="/tmp/tv.log"
LOGO_FILE="/app/hichrawi-logo-crop.png"
STREAM_ROOT="/stream"
A_DIR="$STREAM_ROOT/source_a"
B_DIR="$STREAM_ROOT/source_b"

# Prevent two controller scripts from running at the same time.
LOCK_DIR="/tmp/hichrawi-tv-controller.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[TV] Another start-tv.sh is already running. Exiting."
    exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

mkdir -p "$A_DIR" "$B_DIR"
touch "$LOG_FILE"

log() {
    echo "[TV] $*" | tee -a "$LOG_FILE"
}

json_value() {
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    v = d.get(sys.argv[2], "")
    print(v if v is not None else "")
except Exception:
    print("")
PY
}

write_json_atomic() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, sys, time
from pathlib import Path

path = Path(sys.argv[1])
data = {
    "status": sys.argv[2],
    "active_source": sys.argv[3],
    "active_name": sys.argv[4],
    "active_dir": sys.argv[5],
    "updated_at": time.time()
}
if sys.argv[6]:
    data["message"] = sys.argv[6]

tmp = path.with_suffix(".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
tmp.replace(path)
PY
}

save_source() {
    python3 - "$SOURCE_FILE" "$1" "$2" <<'PY'
import json, sys
from pathlib import Path

p = Path(sys.argv[1])
data = {
    "type": "iptv",
    "url": sys.argv[2],
}
if sys.argv[3]:
    data["name"] = sys.argv[3]

tmp = p.with_suffix(".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
tmp.replace(p)
PY
}

clean_dir() {
    rm -f "$1"/*.ts "$1"/*.m3u8 "$1"/*.tmp 2>/dev/null || true
}

pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

playlist_ready() {
    local dir="$1"
    local playlist="$dir/stream.m3u8"

    [ -s "$playlist" ] || return 1

    grep -q '^#EXTINF:' "$playlist" 2>/dev/null || return 1

    local count
    count=$(find "$dir" -maxdepth 1 -type f -name '*.ts' 2>/dev/null | wc -l)
    [ "$count" -ge 3 ]
}

wait_ready() {
    local dir="$1"
    local pid="$2"
    local timeout="${3:-30}"
    local i=0

    while [ "$i" -lt "$timeout" ]; do
        if playlist_ready "$dir"; then
            return 0
        fi

        if ! pid_alive "$pid"; then
            return 1
        fi

        sleep 1
        i=$((i + 1))
    done

    return 1
}

start_ffmpeg() {
    local source="$1"
    local dir="$2"
    local prefix="$3"

    clean_dir "$dir"

    log "Starting FFmpeg: $source"
    log "HLS directory: $dir"

    local input_options=()

    if [[ "$source" == http://* || "$source" == https://* ]]; then
        input_options=(
            -reconnect 1
            -reconnect_streamed 1
            -reconnect_at_eof 1
            -reconnect_delay_max 10
            -rw_timeout 15000000
        )
    fi

    ffmpeg \
        -hide_banner \
        -loglevel warning \
        "${input_options[@]}" \
        -fflags +genpts+discardcorrupt \
        -thread_queue_size 2048 \
        -i "$source" \
        -loop 1 \
        -framerate 25 \
        -thread_queue_size 64 \
        -i "$LOGO_FILE" \
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
        -hls_segment_filename "$dir/${prefix}_%06d.ts" \
        "$dir/stream.m3u8" \
        >>"$LOG_FILE" 2>&1 &

    echo $!
}

# ---- Initial source ----

CURRENT_SOURCE=$(json_value "$SOURCE_FILE" "url")
CURRENT_NAME=$(json_value "$SOURCE_FILE" "name")

if [ -z "$CURRENT_SOURCE" ]; then
    CURRENT_SOURCE="/app/videos/videos/1.mp4"
    CURRENT_NAME="الفيديو المحلي"
fi

CURRENT_DIR="source_a"
CURRENT_PATH="$A_DIR"
CURRENT_PREFIX="stream_a"

OTHER_DIR="source_b"
OTHER_PATH="$B_DIR"
OTHER_PREFIX="stream_b"

log "HICHRAWI-TV starting..."
log "Main source: $CURRENT_SOURCE"

write_json_atomic "$STATE_FILE" "starting" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" ""

CURRENT_PID=$(start_ffmpeg "$CURRENT_SOURCE" "$CURRENT_PATH" "$CURRENT_PREFIX")
log "FFmpeg PID: $CURRENT_PID"

if wait_ready "$CURRENT_PATH" "$CURRENT_PID" 45; then
    write_json_atomic "$STATE_FILE" "active" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" ""
    log "HICHRAWI-TV is LIVE."
else
    log "Main source failed to become ready."

    if pid_alive "$CURRENT_PID"; then
        kill "$CURRENT_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$CURRENT_PID" 2>/dev/null || true
    fi

    # Local video is the emergency startup source.
    if [ "$CURRENT_SOURCE" != "/app/videos/videos/1.mp4" ] && [ -f "/app/videos/videos/1.mp4" ]; then
        CURRENT_SOURCE="/app/videos/videos/1.mp4"
        CURRENT_NAME="الفيديو المحلي"
        clean_dir "$CURRENT_PATH"

        CURRENT_PID=$(start_ffmpeg "$CURRENT_SOURCE" "$CURRENT_PATH" "$CURRENT_PREFIX")

        if wait_ready "$CURRENT_PATH" "$CURRENT_PID" 45; then
            write_json_atomic "$STATE_FILE" "active" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" "main source failed; local video active"
            log "Local video is LIVE."
        else
            write_json_atomic "$STATE_FILE" "error" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" "no source became ready"
            log "No source became ready."
        fi
    fi
fi

# ---- Control loop ----
while true; do
    # If the active FFmpeg dies unexpectedly, restart ONLY the active source.
    if ! pid_alive "$CURRENT_PID"; then
        log "Active FFmpeg stopped. Restarting current source."

        clean_dir "$CURRENT_PATH"
        CURRENT_PID=$(start_ffmpeg "$CURRENT_SOURCE" "$CURRENT_PATH" "$CURRENT_PREFIX")

        if wait_ready "$CURRENT_PATH" "$CURRENT_PID" 45; then
            write_json_atomic "$STATE_FILE" "active" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" ""
            log "Current source recovered."
        else
            write_json_atomic "$STATE_FILE" "error" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" "active source failed"
            log "Current source could not be recovered."
        fi
    fi

    if [ -f "$REQUEST_FILE" ]; then
        REQUEST_SOURCE=$(json_value "$REQUEST_FILE" "url")
        REQUEST_NAME=$(json_value "$REQUEST_FILE" "name")

        # Ignore malformed/empty requests.
        if [ -z "$REQUEST_SOURCE" ]; then
            rm -f "$REQUEST_FILE"
        elif [ "$REQUEST_SOURCE" = "$CURRENT_SOURCE" ]; then
            log "Requested source is already active: $REQUEST_SOURCE"
            rm -f "$REQUEST_FILE"
        else
            log "SOURCE CHANGE REQUEST: $REQUEST_NAME -> $REQUEST_SOURCE"

            # Start the new source in the inactive buffer.
            clean_dir "$OTHER_PATH"
            write_json_atomic "$STATE_FILE" "testing" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" "testing new source"

            NEW_PID=$(start_ffmpeg "$REQUEST_SOURCE" "$OTHER_PATH" "$OTHER_PREFIX")

            if wait_ready "$OTHER_PATH" "$NEW_PID" 45; then
                log "New source is READY. Switching without stopping current source."

                OLD_PID="$CURRENT_PID"
                OLD_DIR="$CURRENT_DIR"
                OLD_PATH="$CURRENT_PATH"

                # Atomic state switch. hls_server.py reads this before
                # selecting the active A/B playlist.
                write_json_atomic "$STATE_FILE" "switching" "$REQUEST_SOURCE" "$REQUEST_NAME" "$OTHER_DIR" "new source ready"

                CURRENT_SOURCE="$REQUEST_SOURCE"
                CURRENT_NAME="$REQUEST_NAME"
                CURRENT_DIR="$OTHER_DIR"
                CURRENT_PATH="$OTHER_PATH"
                CURRENT_PREFIX="$OTHER_PREFIX"
                CURRENT_PID="$NEW_PID"

                if [ "$CURRENT_DIR" = "source_a" ]; then
                    OTHER_DIR="source_b"
                    OTHER_PATH="$B_DIR"
                    OTHER_PREFIX="stream_b"
                else
                    OTHER_DIR="source_a"
                    OTHER_PATH="$A_DIR"
                    OTHER_PREFIX="stream_a"
                fi

                # Make the selected source persistent for the next restart.
                save_source "$CURRENT_SOURCE" "$CURRENT_NAME"

                write_json_atomic "$STATE_FILE" "active" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" ""

                # Give clients time to request the new playlist/segments.
                sleep 8

                if pid_alive "$OLD_PID"; then
                    kill "$OLD_PID" 2>/dev/null || true
                    sleep 1
                    kill -9 "$OLD_PID" 2>/dev/null || true
                fi

                log "SOURCE SWITCH COMPLETE: $CURRENT_NAME"
                rm -f "$REQUEST_FILE"
            else
                log "New source FAILED. Keeping current source LIVE."

                if pid_alive "$NEW_PID"; then
                    kill "$NEW_PID" 2>/dev/null || true
                    sleep 1
                    kill -9 "$NEW_PID" 2>/dev/null || true
                fi

                clean_dir "$OTHER_PATH"
                write_json_atomic "$STATE_FILE" "active" "$CURRENT_SOURCE" "$CURRENT_NAME" "$CURRENT_DIR" "new source failed; current source kept"
                rm -f "$REQUEST_FILE"
            fi
        fi
    fi

    sleep 1
done
