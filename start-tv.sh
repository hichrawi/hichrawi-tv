#!/bin/bash

while true
do
    rm -f /stream/*.ts /stream/*.m3u8 /stream/*.tmp

    SOURCE="/app/videos/videos/1.mp4"

    echo "[TV] Starting HICHRAWI-TV..." | tee -a /tmp/tv.log

    ffmpeg \
    -hide_banner \
    -loglevel info \
    -re \
    -stream_loop -1 \
    -thread_queue_size 2048 \
    -i "$SOURCE" \
    -thread_queue_size 64 \
    -loop 1 \
    -framerate 30 \
    -i "/app/hichrawi-logo-crop.png" \
    -filter_complex "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30,format=yuv420p[outv]" \
    -map "[outv]" \
    -map 0:a:0? \
    -c:v libx264 \
    -preset superfast \
    -tune zerolatency \
    -profile:v main \
    -level:v 3.1 \
    -pix_fmt yuv420p \
    -r 30 \
    -crf 24 \
    -g 180 \
    -keyint_min 180 \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*6)" \
    -c:a aac \
    -profile:a aac_low \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    -f hls \
    -hls_time 6 \
    -hls_list_size 12 \
    -hls_delete_threshold 6 \
    -hls_flags delete_segments+independent_segments+append_list \
    -hls_segment_type mpegts \
    -hls_allow_cache 0 \
    -hls_playlist_type event \
    -hls_segment_filename "/stream/stream%03d.ts" \
    "/stream/stream.m3u8"

    echo "[TV] FFmpeg stopped. Restarting in 3 seconds..." | tee -a /tmp/tv.log
    sleep 3
done
