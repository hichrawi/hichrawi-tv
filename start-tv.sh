#!/bin/bash
set -u

mkdir -p /stream /app/videos

# HLS/API server.
python3 /app/hls_server.py >/app/hls_server.log 2>&1 &

# Stream engine:
# - keeps current source alive
# - retries FFmpeg automatically
# - prepares a new source before switching
python3 /app/stream_engine.py >/app/stream_engine.out 2>&1 &

wait -n
exit $?
