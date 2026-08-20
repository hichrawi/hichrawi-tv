#!/bin/bash

SOURCE_FILE="/app/source.json"
REQUEST_FILE="/app/source_request.json"
STATE_FILE="/app/stream_state.json"
LOG_FILE="/tmp/tv.log"

STREAM_ROOT="/stream"
SOURCE_A="$STREAM_ROOT/source_a"
SOURCE_B="$STREAM_ROOT/source_b"

mkdir -p "$SOURCE_A" "$SOURCE_B"

CURRENT_SOURCE=""
CURRENT_NAME=""
CURRENT_DIR="source_a"
FFMPEG_PID=""

log() {
    echo "[TV] $1" | tee -a "$LOG_FILE"
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
    python3 - "$STATE_FILE" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import sys
import time

path = sys.argv[1]

data = {
    "status": sys.argv[2],
    "active_source": sys.argv[3],
    "active_name": sys.argv[4],
    "active_dir": sys.argv[5],
    "message": sys.argv[6],
    "updated_at": time.time()
}

tmp = path + ".tmp"

with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)

import os
os.replace(tmp, path)
PY
}

source_is_file() {
    case "$1" in
        /*)
            [ -f "$1" ]
            return
            ;;
    esac

    return 1
}

start_ffmpeg() {
    local SOURCE="$1"
    local DIR="$2"
    local PREFIX="$3"

    local OUT="$STREAM_ROOT/$DIR"

    rm -f "$OUT"/*.ts
    rm -f "$OUT"/*.m3u8
    rm -f "$OUT"/*.tmp

    log "Starting candidate/current source:"
    log "Source: $SOURCE"
    log "Directory: $DIR"

    ffmpeg \
        -hide_banner \
        -loglevel warning \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_at_eof 1 \
        -reconnect_delay_max 10 \
        -rw_timeout 15000000 \
        -fflags +genpts+discardcorrupt \
        -thread_queue_size 2048 \
        -re \
        -i "$SOURCE" \
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
        -hls_segment_filename "$OUT/${PREFIX}%06d.ts" \
        "$OUT/stream.m3u8" \
        >>"$LOG_FILE" 2>&1 &

    echo $!
}

playlist_ready() {
    local DIR="$1"
    local PLAYLIST="$STREAM_ROOT/$DIR/stream.m3u8"

    [ -s "$PLAYLIST" ] || return 1

    grep -q "#EXTINF:" "$PLAYLIST" || return 1

    local SEGMENT

    SEGMENT=$(grep -E '\.ts$' "$PLAYLIST" | tail -1)

    [ -n "$SEGMENT" ] || return 1

    [ -f "$STREAM_ROOT/$DIR/$SEGMENT" ] || return 1

    return 0
}

wait_candidate() {
    local DIR="$1"
    local PID="$2"

    local i=0

    while [ "$i" -lt 30 ]
    do
        if ! kill -0 "$PID" 2>/dev/null; then
            log "Candidate FFmpeg stopped before becoming ready."
            return 1
        fi

        if playlist_ready "$DIR"; then
            log "Candidate source is READY."
            return 0
        fi

        sleep 1
        i=$((i + 1))
    done

    log "Candidate source did not become ready within 30 seconds."

    return 1
}

switch_state() {
    local DIR="$1"
    local SOURCE="$2"
    local NAME="$3"

    write_state \
        "active" \
        "$SOURCE" \
        "$NAME" \
        "$DIR" \
        "source active" \
        ""
}

cleanup_old_later() {
    local DIR="$1"

    (
        sleep 60

        rm -f "$STREAM_ROOT/$DIR"/*.ts
        rm -f "$STREAM_ROOT/$DIR"/*.m3u8
        rm -f "$STREAM_ROOT/$DIR"/*.tmp

        log "Old stream directory cleaned: $DIR"
    ) &
}

# --------------------------------------------------
# INITIAL SOURCE
# --------------------------------------------------

CURRENT_SOURCE=$(get_json_value "$SOURCE_FILE" "url")
CURRENT_NAME=$(get_json_value "$SOURCE_FILE" "name")

if [ -z "$CURRENT_SOURCE" ]; then
    CURRENT_SOURCE="/app/videos/videos/1.mp4"
fi

if [ -z "$CURRENT_NAME" ]; then
    CURRENT_NAME="الوطنية 1"
fi

CURRENT_DIR="source_a"

log "======================================"
log "HICHRAWI-TV starting..."
log "Main source: $CURRENT_SOURCE"
log "Main name: $CURRENT_NAME"
log "======================================"

write_state \
    "starting" \
    "$CURRENT_SOURCE" \
    "$CURRENT_NAME" \
    "$CURRENT_DIR" \
    "starting main source" \
    ""

FFMPEG_PID=$(start_ffmpeg \
    "$CURRENT_SOURCE" \
    "$CURRENT_DIR" \
    "stream_a_")

log "Main FFmpeg PID: $FFMPEG_PID"

if wait_candidate "$CURRENT_DIR" "$FFMPEG_PID"; then

    switch_state \
        "$CURRENT_DIR" \
        "$CURRENT_SOURCE" \
        "$CURRENT_NAME"

    log "HICHRAWI-TV is LIVE."

else

    log "Main source failed to start."

    kill -9 "$FFMPEG_PID" 2>/dev/null || true

    exit 1
fi


# --------------------------------------------------
# CONTROL LOOP
# --------------------------------------------------

while true
do

    if [ -f "$REQUEST_FILE" ]; then

        REQUEST_SOURCE=$(get_json_value "$REQUEST_FILE" "url")
        REQUEST_NAME=$(get_json_value "$REQUEST_FILE" "name")

        if [ -z "$REQUEST_SOURCE" ]; then
            rm -f "$REQUEST_FILE"
            sleep 1
            continue
        fi

        if [ -z "$REQUEST_NAME" ]; then
            REQUEST_NAME="المصدر الجديد"
        fi

        if [ "$REQUEST_SOURCE" = "$CURRENT_SOURCE" ]; then

            log "Requested source is already active."

            rm -f "$REQUEST_FILE"

            sleep 1
            continue
        fi

        # ------------------------------------------
        # Choose inactive directory.
        # ------------------------------------------

        if [ "$CURRENT_DIR" = "source_a" ]; then
            CANDIDATE_DIR="source_b"
            CANDIDATE_PREFIX="stream_b_"
        else
            CANDIDATE_DIR="source_a"
            CANDIDATE_PREFIX="stream_a_"
        fi

        log "======================================"
        log "NEW SOURCE REQUEST"
        log "Name: $REQUEST_NAME"
        log "URL: $REQUEST_SOURCE"
        log "Candidate directory: $CANDIDATE_DIR"
        log "Current source remains LIVE."
        log "======================================"

        write_state \
            "testing" \
            "$CURRENT_SOURCE" \
            "$CURRENT_NAME" \
            "$CURRENT_DIR" \
            "testing new source" \
            "$REQUEST_NAME"

        # ------------------------------------------
        # Start new source WITHOUT touching current.
        # ------------------------------------------

        CANDIDATE_PID=$(start_ffmpeg \
            "$REQUEST_SOURCE" \
            "$CANDIDATE_DIR" \
            "$CANDIDATE_PREFIX")

        log "Candidate FFmpeg PID: $CANDIDATE_PID"

        # ------------------------------------------
        # Wait for candidate HLS.
        # ------------------------------------------

        if wait_candidate \
            "$CANDIDATE_DIR" \
            "$CANDIDATE_PID"; then

            log "Candidate source passed HLS readiness check."

            # --------------------------------------
            # Atomic logical switch.
            # --------------------------------------

            OLD_DIR="$CURRENT_DIR"
            OLD_PID="$FFMPEG_PID"

            CURRENT_DIR="$CANDIDATE_DIR"
            CURRENT_SOURCE="$REQUEST_SOURCE"
            CURRENT_NAME="$REQUEST_NAME"
            FFMPEG_PID="$CANDIDATE_PID"

            switch_state \
                "$CURRENT_DIR" \
                "$CURRENT_SOURCE" \
                "$CURRENT_NAME"

            log "======================================"
            log "SOURCE SWITCH SUCCESS"
            log "Active: $CURRENT_NAME"
            log "Directory: $CURRENT_DIR"
            log "======================================"

            rm -f "$REQUEST_FILE"

            # --------------------------------------
            # Give IPTV clients time to move to the
            # new playlist before stopping old FFmpeg.
            # --------------------------------------

            sleep 8

            if kill -0 "$OLD_PID" 2>/dev/null; then
                kill "$OLD_PID" 2>/dev/null || true
                sleep 2
                kill -9 "$OLD_PID" 2>/dev/null || true
            fi

            # Keep old segments temporarily.
            cleanup_old_later "$OLD_DIR"

        else

            log "======================================"
            log "SOURCE SWITCH FAILED"
            log "Keeping current source:"
            log "$CURRENT_NAME"
            log "======================================"

            write_state \
                "active" \
                "$CURRENT_SOURCE" \
                "$CURRENT_NAME" \
                "$CURRENT_DIR" \
                "new source failed; current source kept" \
                "$REQUEST_NAME"

            kill -9 "$CANDIDATE_PID" 2>/dev/null || true

            rm -f "$CANDIDATE_DIR"/*.ts
            rm -f "$CANDIDATE_DIR"/*.m3u8
            rm -f "$CANDIDATE_DIR"/*.tmp

            rm -f "$REQUEST_FILE"

        fi
    fi

    # ----------------------------------------------
    # Make sure active FFmpeg is alive.
    # ----------------------------------------------

    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then

        log "ACTIVE FFmpeg stopped."

        if [ -f "$REQUEST_FILE" ]; then
            rm -f "$REQUEST_FILE"
        fi

        write_state \
            "restarting" \
            "$CURRENT_SOURCE" \
            "$CURRENT_NAME" \
            "$CURRENT_DIR" \
            "active FFmpeg stopped" \
            ""

        FFMPEG_PID=$(start_ffmpeg \
            "$CURRENT_SOURCE" \
            "$CURRENT_DIR" \
            "stream_${CURRENT_DIR}_")

        if wait_candidate \
            "$CURRENT_DIR" \
            "$FFMPEG_PID"; then

            switch_state \
                "$CURRENT_DIR" \
                "$CURRENT_SOURCE" \
                "$CURRENT_NAME"

            log "Active source restarted successfully."

        else

            log "Active source failed to restart."

            kill -9 "$FFMPEG_PID" 2>/dev/null || true

            sleep 5
        fi
    fi

    sleep 1

done
