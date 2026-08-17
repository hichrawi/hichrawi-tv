#!/bin/bash
set -u

# HICHRAWI-TV recovery runtime.
# Existing IPTV source and logo are preserved.
# Do not delete all HLS files on every retry.

mkdir -p /stream

start_hls() {
    if ! pgrep -f "python3 /app/hls_server.py" >/dev/null 2>&1; then
        python3 /app/hls_server.py >/app/hls_server.log 2>&1 &
    fi
}

start_hls

while true
do
    SOURCE=$(python3 -c "import json; print(json.load(open('/app/source.json'))['url'])")

    ffmpeg -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1       -reconnect_delay_max 10 -rw_timeout 15000000       -i "$SOURCE"       -i "/app/hichrawi-logo-crop.png"       -filter_complex "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30"       -c:v libx264 -preset veryfast -c:a copy       -f hls -hls_time 6 -hls_list_size 15       -hls_flags delete_segments+append_list       /stream/stream.m3u8

    # If FFmpeg exits, keep the HLS server alive and retry automatically.
    start_hls
    sleep 3
done
