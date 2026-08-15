#!/bin/bash

while true; do
    rm -f /stream/*.ts /stream/*.m3u8 /stream/*.tmp

    ffmpeg \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_at_eof 1 \
    -reconnect_delay_max 10 \
    -rw_timeout 15000000 \
    -i "http://071024.com:88/02029921082595/02029921082595/638988" \
    -c:v copy \
    -c:a copy \
    -f hls \
    -hls_time 6 \
    -hls_list_size 15 \
    -hls_flags delete_segments+append_list \
    /stream/stream.m3u8

    echo "FFmpeg stopped. Restarting in 3 seconds..."
    sleep 3
done
