#!/bin/bash

while true
do

rm -f /stream/*.ts /stream/*.m3u8 /stream/*.tmp

TYPE=$(python3 -c "import json; print(json.load(open('/app/source.json')).get('type','iptv'))")
SOURCE=$(python3 -c "import json; print(json.load(open('/app/source.json')).get('url',''))")

if [ "$TYPE" = "video" ]; then
    INPUT="$SOURCE"
else
    INPUT="$SOURCE"
fi

ffmpeg \
-reconnect 1 \
-reconnect_streamed 1 \
-reconnect_at_eof 1 \
-reconnect_delay_max 10 \
-rw_timeout 15000000 \
-re -i "$INPUT" \
-i "/app/hichrawi-logo-crop.png" \
-filter_complex "[1:v]scale=180:-1[logo];[0:v][logo]overlay=W-w-30:30" \
-c:v libx264 \
-preset veryfast \
-c:a aac \
-f hls \
-hls_time 6 \
-hls_list_size 15 \
-hls_flags delete_segments+append_list \
/stream/stream.m3u8

sleep 3

done
