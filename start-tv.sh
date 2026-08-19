#!/bin/bash

while true
do
    rm -f /stream/*.ts /stream/*.m3u8 /stream/*.tmp

    SOURCE=$(python3 -c "import json; print(json.load(open('/app/source.json'))['url'])")

    ffmpeg \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_at_eof 1 \
    -reconnect_delay_max 10 \
    -rw_timeout 15000000 \
    -i "$SOURCE" \
    -i "/app/hichrawi-logo-crop.png" \
    -filter_complex "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30" \
    -map 0:v:0 \
    -map 0:a:0? \
    -c:v libx264 \
    -preset veryfast \
    -profile:v main \
    -level:v 4.0 \
    -pix_fmt yuv420p \
    -crf 23 \
    -force_key_frames "expr:gte(t,n_forced*6)" \
    -c:a aac \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    -f hls \
    -hls_time 6 \
    -hls_list_size 20 \
    -hls_delete_threshold 10 \
    -hls_flags delete_segments+append_list \
    -hls_segment_type mpegts \
    -hls_allow_cache 0 \
    /stream/stream.m3u8

    sleep 3
done
