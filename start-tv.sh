#!/bin/bash

while true
do
    rm -f /stream/*.ts /stream/*.m3u8 /stream/*.tmp

    SOURCE=$(python3 -c "import json; print(json.load(open('/app/source.json'))['url'])")

    if [ -z "$SOURCE" ]; then
        SOURCE="/app/videos/videos/1.mp4"
    fi

    echo "[TV] Starting HICHRAWI-TV source: $SOURCE" | tee -a /tmp/tv.log

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

    echo "[TV] FFmpeg stopped. Restarting in 3 seconds..." | tee -a /tmp/tv.log
    sleep 3
done
