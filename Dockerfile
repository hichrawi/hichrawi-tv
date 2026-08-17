FROM ubuntu:24.04
RUN apt update && apt install -y ffmpeg python3 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY hls_server.py /app/
COPY start-tv.sh /app/
COPY hichrawi-logo-crop.png /app/
COPY source.json /app/
RUN chmod +x /app/start-tv.sh
RUN mkdir -p /stream
EXPOSE 8080
CMD ["bash", "/app/start-tv.sh"]
