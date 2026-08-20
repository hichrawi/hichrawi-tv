#!/bin/bash

SOURCE_FILE="/app/source.json"
REQUEST_FILE="/app/source_request.json"
LOG_FILE="/tmp/tv.log"

CURRENT_SOURCE=""

get_source() {
    python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print((data.get("url") or "").strip())
except Exception:
    print("")
PY
}

get_request_source() {
    [ -f "$REQUEST_FILE" ] || return 0

    python3 - "$REQUEST_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print((data.get("url") or "").strip())
except Exception:
    print("")
PY
}

start_ffmpeg() {
    local SOURCE="$1"

    rm -f /stream/*.ts /stream/*.m3u8 /stream/*.tmp

    echo "[TV] Starting HICHRAWI-TV source: $SOURCE" | tee -a "$LOG_FILE"

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
    -hls_segment_filename "/stream/stream%03d.ts" \
    "/stream/stream.m3u8"
}

# المصدر الرئيسي
CURRENT_SOURCE=$(get_source "$SOURCE_FILE")

# إذا source.json فارغ → الفيديو المحلي
if [ -z "$CURRENT_SOURCE" ]; then
    CURRENT_SOURCE="/app/videos/videos/1.mp4"
fi

echo "[TV] HICHRAWI-TV starting..." | tee -a "$LOG_FILE"
echo "[TV] Main source: $CURRENT_SOURCE" | tee -a "$LOG_FILE"

while true
do
    # شغّل FFmpeg في الخلفية حتى نقدروا نراقبوا طلب تغيير المصدر
    start_ffmpeg "$CURRENT_SOURCE" >>"$LOG_FILE" 2>&1 &
    FFMPEG_PID=$!

    echo "[TV] FFmpeg PID: $FFMPEG_PID" | tee -a "$LOG_FILE"

    SWITCHED=0

    # نراقب المصدر أثناء تشغيل FFmpeg
    while kill -0 "$FFMPEG_PID" 2>/dev/null
    do
        if [ -f "$REQUEST_FILE" ]; then
            REQUEST_SOURCE=$(get_request_source)

            if [ -n "$REQUEST_SOURCE" ] && [ "$REQUEST_SOURCE" != "$CURRENT_SOURCE" ]; then

                echo "[TV] New source requested: $REQUEST_SOURCE" | tee -a "$LOG_FILE"

                # نوقف FFmpeg الحالي بطريقة نظيفة
                kill -TERM "$FFMPEG_PID" 2>/dev/null

                # نعطيه وقت صغير باش يغلق HLS
                for i in 1 2 3 4 5
                do
                    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
                        break
                    fi
                    sleep 1
                done

                # إذا ما وقفش
                if kill -0 "$FFMPEG_PID" 2>/dev/null; then
                    kill -KILL "$FFMPEG_PID" 2>/dev/null
                fi

                wait "$FFMPEG_PID" 2>/dev/null

                CURRENT_SOURCE="$REQUEST_SOURCE"

                echo "[TV] Switching to: $CURRENT_SOURCE" | tee -a "$LOG_FILE"

                # الطلب تم استهلاكه
                rm -f "$REQUEST_FILE"

                SWITCHED=1
                break
            fi
        fi

        sleep 1
    done

    # انتظر FFmpeg
    wait "$FFMPEG_PID" 2>/dev/null

    if [ "$SWITCHED" -eq 1 ]; then
        echo "[TV] Source switch completed." | tee -a "$LOG_FILE"
        sleep 2
        continue
    fi

    echo "[TV] FFmpeg stopped. Restarting current source..." | tee -a "$LOG_FILE"

    sleep 3
done
