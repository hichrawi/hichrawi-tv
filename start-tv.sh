#!/bin/bash

SOURCE_FILE="/app/source.json"
REQUEST_FILE="/app/source_request.json"
STATE_FILE="/app/stream_state.json"
LOG_FILE="/tmp/tv.log"

CURRENT_SOURCE=""
CURRENT_NAME=""

get_json_value() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

file = sys.argv[1]
key = sys.argv[2]

try:
    with open(file, "r", encoding="utf-8") as f:
        data = json.load(f)
    value = data.get(key, "")
    print(value if value is not None else "")
except Exception:
    print("")
PY
}

write_state() {
    local status="$1"
    local source="$2"
    local name="$3"
    local error="${4:-}"

    python3 - "$STATE_FILE" "$status" "$source" "$name" "$error" <<'PY'
import json
import sys
import time
from pathlib import Path

file = Path(sys.argv[1])
status = sys.argv[2]
source = sys.argv[3]
name = sys.argv[4]
error = sys.argv[5]

data = {
    "status": status,
    "active_source": source,
    "active_name": name,
    "updated_at": time.time()
}

if error:
    data["error"] = error

tmp = file.with_suffix(".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
tmp.replace(file)
PY
}

cleanup_hls() {
    rm -f /stream/*.ts
    rm -f /stream/*.m3u8
    rm -f /stream/*.tmp
}

start_ffmpeg() {
    local SOURCE="$1"

    cleanup_hls

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

# --------------------------------------------------
# المصدر الرئيسي
# --------------------------------------------------

CURRENT_SOURCE=$(get_json_value "$SOURCE_FILE" "url")
CURRENT_NAME="المصدر الرئيسي"

if [ -z "$CURRENT_SOURCE" ]; then
    CURRENT_SOURCE="/app/videos/videos/1.mp4"
    CURRENT_NAME="الفيديو المحلي"
fi

echo "[TV] HICHRAWI-TV starting..." | tee -a "$LOG_FILE"
echo "[TV] Main source: $CURRENT_SOURCE" | tee -a "$LOG_FILE"

write_state "starting" "$CURRENT_SOURCE" "$CURRENT_NAME"

# --------------------------------------------------
# الحلقة الرئيسية
# --------------------------------------------------

while true
do
    echo "[TV] Starting active source..." | tee -a "$LOG_FILE"

    write_state "starting" "$CURRENT_SOURCE" "$CURRENT_NAME"

    start_ffmpeg "$CURRENT_SOURCE" >>"$LOG_FILE" 2>&1 &
    FFMPEG_PID=$!

    echo "[TV] FFmpeg PID: $FFMPEG_PID" | tee -a "$LOG_FILE"

    # --------------------------------------------------
    # مراقبة FFmpeg + طلبات تغيير المصدر
    # --------------------------------------------------

    SWITCH_REQUESTED=0

    while kill -0 "$FFMPEG_PID" 2>/dev/null
    do
        if [ -f "$REQUEST_FILE" ]; then

            REQUEST_SOURCE=$(get_json_value "$REQUEST_FILE" "url")
            REQUEST_NAME=$(get_json_value "$REQUEST_FILE" "name")

            if [ -n "$REQUEST_SOURCE" ] && [ "$REQUEST_SOURCE" != "$CURRENT_SOURCE" ]; then

                echo "[TV] ======================================" | tee -a "$LOG_FILE"
                echo "[TV] NEW SOURCE REQUEST" | tee -a "$LOG_FILE"
                echo "[TV] Name: $REQUEST_NAME" | tee -a "$LOG_FILE"
                echo "[TV] URL:  $REQUEST_SOURCE" | tee -a "$LOG_FILE"
                echo "[TV] ======================================" | tee -a "$LOG_FILE"

                write_state "switching" "$CURRENT_SOURCE" "$CURRENT_NAME"

                # --------------------------------------------------
                # نختبر المصدر الجديد قبل إسقاط المصدر الحالي
                # --------------------------------------------------

                echo "[TV] Testing new source..." | tee -a "$LOG_FILE"

                TEST_OK=0

                ffmpeg \
                -hide_banner \
                -loglevel error \
                -reconnect 1 \
                -reconnect_streamed 1 \
                -reconnect_at_eof 1 \
                -reconnect_delay_max 5 \
                -rw_timeout 10000000 \
                -i "$REQUEST_SOURCE" \
                -map 0:v:0 \
                -map 0:a:0? \
                -t 8 \
                -f null - \
                >/tmp/source_test.log 2>&1

                TEST_EXIT=$?

                if [ "$TEST_EXIT" -eq 0 ]; then
                    TEST_OK=1
                fi

                if [ "$TEST_OK" -eq 1 ]; then

                    echo "[TV] New source test PASSED." | tee -a "$LOG_FILE"

                    # نوقف المصدر الحالي
                    kill -TERM "$FFMPEG_PID" 2>/dev/null

                    for i in 1 2 3 4 5
                    do
                        if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
                            break
                        fi
                        sleep 1
                    done

                    if kill -0 "$FFMPEG_PID" 2>/dev/null; then
                        kill -KILL "$FFMPEG_PID" 2>/dev/null
                    fi

                    wait "$FFMPEG_PID" 2>/dev/null

                    # المصدر الجديد يصبح الحالي
                    CURRENT_SOURCE="$REQUEST_SOURCE"

                    if [ -n "$REQUEST_NAME" ]; then
                        CURRENT_NAME="$REQUEST_NAME"
                    else
                        CURRENT_NAME="المصدر الجديد"
                    fi

                    # نحذف الطلب بعد نجاح التبديل
                    rm -f "$REQUEST_FILE"

                    echo "[TV] SOURCE SWITCHED SUCCESSFULLY." | tee -a "$LOG_FILE"
                    echo "[TV] Active: $CURRENT_NAME" | tee -a "$LOG_FILE"

                    write_state "active" "$CURRENT_SOURCE" "$CURRENT_NAME"

                    SWITCH_REQUESTED=1
                    break

                else

                    echo "[TV] New source test FAILED." | tee -a "$LOG_FILE"
                    echo "[TV] Current source remains active." | tee -a "$LOG_FILE"

                    write_state \
                        "failed" \
                        "$CURRENT_SOURCE" \
                        "$CURRENT_NAME" \
                        "المصدر الجديد غير صالح أو لا يمكن الوصول إليه"

                    # نحذف الطلب الفاشل حتى لا يعاود التبديل كل ثانية
                    rm -f "$REQUEST_FILE"

                fi
            fi
        fi

        sleep 1
    done

    # --------------------------------------------------
    # FFmpeg توقف
    # --------------------------------------------------

    wait "$FFMPEG_PID" 2>/dev/null

    if [ "$SWITCH_REQUESTED" -eq 1 ]; then
        echo "[TV] Restarting with new active source..." | tee -a "$LOG_FILE"
        sleep 2
        continue
    fi

    # --------------------------------------------------
    # FFmpeg توقف بسبب المصدر / الشبكة
    # --------------------------------------------------

    echo "[TV] ACTIVE FFmpeg stopped." | tee -a "$LOG_FILE"
    echo "[TV] Restarting current source in 3 seconds..." | tee -a "$LOG_FILE"

    write_state "restarting" "$CURRENT_SOURCE" "$CURRENT_NAME"

    sleep 3
done
