```bash
#!/bin/bash

while true
do
    rm -f /stream/*.ts /stream/*.m3u8 /stream/*.tmp

    SOURCE=$(python3 -c "import json; print(json.load(open('/app/source.json'))['url'])")

    echo "[TV] Starting HICHRAWI-TV source..." | tee -a /tmp/tv.log

    ffmpeg \
    -hide_banner \
    -loglevel info \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_at_eof 1 \
    -reconnect_delay_max 10 \
    -rw_timeout 15000000 \
    -thread_queue_size 2048 \
    -re \
    -i "$SOURCE" \
    -thread_queue_size 64 \
    -loop 1 \
    -framerate 25 \
    -i "/app/hichrawi-logo-crop.png" \
    -filter_complex "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30,format=yuv420p[outv]" \
    -map "[outv]" \
    -map 0:a:0? \
    -c:v libx264 \
    -preset veryfast \
    -profile:v main \
    -level:v 3.1 \
    -pix_fmt yuv420p \
    -crf 23 \
    -g 150 \
    -keyint_min 150 \
    -sc_threshold 0 \
    -c:a aac \
    -profile:a aac_low \
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
    -hls_playlist_type event \
    /stream/stream.m3u8

    echo "[TV] FFmpeg stopped. Restarting in 3 seconds..." | tee -a /tmp/tv.log
    sleep 3
done
```
