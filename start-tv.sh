#!/bin/bash
set -u
mkdir -p /stream /app/videos

echo "[HICHRAWI] Starting HLS server..."
python3 /app/hls_server.py 2>&1 | tee -a /app/hls_server.log &

echo "[HICHRAWI] Starting stream engine..."
python3 /app/stream_engine.py 2>&1 | tee -a /app/stream_engine.out &

wait
