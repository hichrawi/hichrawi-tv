FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg python3 python3-venv ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir "firebase-admin>=6.5,<7"

ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app

COPY hls_server_switch.py /app/hls_server_switch.py
COPY source_switcher.py /app/source_switcher.py
COPY start-tv-switch.sh /app/start-tv-switch.sh
COPY hichrawi-logo-crop.png /app/hichrawi-logo-crop.png
COPY source.json /app/source.json

RUN chmod +x /app/start-tv-switch.sh && \
    mkdir -p /stream/main /stream/next

EXPOSE 8080

CMD ["/app/start-tv-switch.sh"]
