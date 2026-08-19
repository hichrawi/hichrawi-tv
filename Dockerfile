FROM ubuntu:24.04

RUN apt update && \
    apt install -y ffmpeg python3 python3-pip ca-certificates && \
    pip3 install --break-system-packages yt-dlp && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Taraji1919.html /app/Taraji1919.html
COPY hls_server.py /app/
COPY stream_engine.py /app/
COPY source_adapter.py /app/
COPY youtube_runner.py /app/
COPY start-tv.sh /app/
COPY hichrawi-logo-crop.png /app/
COPY source.json /app/

RUN chmod +x /app/start-tv.sh /app/hls_server.py /app/stream_engine.py /app/youtube_runner.py
RUN mkdir -p /stream /app/videos

EXPOSE 8080

CMD ["bash","/app/start-tv.sh"]
