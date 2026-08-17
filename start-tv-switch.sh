#!/bin/bash
set -u

mkdir -p /stream/main /stream/next

# The switcher is responsible for the active FFmpeg pipelines.
# The HLS server keeps the public URL unchanged.
python3 /app/hls_server_switch.py >/app/hls_server.log 2>&1 &
HLS_PID=$!

python3 /app/source_switcher.py >/app/source_switcher.log 2>&1 &
SWITCH_PID=$!

cleanup() {
    kill "$SWITCH_PID" "$HLS_PID" 2>/dev/null || true
    wait "$SWITCH_PID" "$HLS_PID" 2>/dev/null || true
}
trap cleanup TERM INT

while true; do
    if ! kill -0 "$HLS_PID" 2>/dev/null; then
        python3 /app/hls_server_switch.py >/app/hls_server.log 2>&1 &
        HLS_PID=$!
    fi

    if ! kill -0 "$SWITCH_PID" 2>/dev/null; then
        python3 /app/source_switcher.py >/app/source_switcher.log 2>&1 &
        SWITCH_PID=$!
    fi

    sleep 5
done
