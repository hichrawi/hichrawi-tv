#!/usr/bin/env python3
import json
import os
import posixpath
import urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

STREAM_ROOT = Path("/stream")
VIDEO_ROOT = Path("/app/videos")
STATE_FILE = Path("/app/stream_state.json")
CONTROL_FILE = Path("/app/source_request.json")

STREAM_ROOT.mkdir(parents=True, exist_ok=True)
VIDEO_ROOT.mkdir(parents=True, exist_ok=True)

def current_dir():
    try:
        data = json.loads(STATE_FILE.read_text())
        name = data.get("active_dir", "source_a")
        if name not in ("source_a", "source_b"):
            name = "source_a"
    except Exception:
        name = "source_a"
    p = STREAM_ROOT / name
    p.mkdir(parents=True, exist_ok=True)
    return p

def safe_video_path(name):
    # Only allow files inside /app/videos.
    p = (VIDEO_ROOT / name).resolve()
    if VIDEO_ROOT.resolve() not in p.parents and p != VIDEO_ROOT.resolve():
        return None
    return p

class Handler(BaseHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Firebase-Api-Key")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def send_json(self, status, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)

        if path == "/api/health":
            self.send_json(200, {"ok": True})
            return

        if path == "/api/videos":
            videos = []
            for p in sorted(VIDEO_ROOT.rglob("*")):
                if p.is_file() and p.suffix.lower() in {
                    ".mp4",".mkv",".webm",".mov",".m4v",".avi",".ts",".m2ts"
                }:
                    rel = p.relative_to(VIDEO_ROOT).as_posix()
                    videos.append({
                        "name": p.name,
                        "filename": p.name,
                        "path": rel,
                        "url": "/videos/" + urllib.parse.quote(rel, safe="/"),
                        "size": p.stat().st_size
                    })
            self.send_json(200, {"videos": videos})
            return

        if path == "/api/source":
            try:
                data = json.loads(CONTROL_FILE.read_text())
            except Exception:
                data = {"status": "unknown"}
            self.send_json(200, data)
            return

        if path in ("/stream.m3u8", "/stream/stream.m3u8"):
            base = current_dir()
            target = base / "stream.m3u8"
            if not target.exists():
                self.send_json(503, {"error": "stream not ready"})
                return
            self.serve_file(target, "application/vnd.apple.mpegurl")
            return

        # HLS segments: support both the new /hls/ path and the
        # legacy /stream/ and root segment paths used by the existing player.
        if path.startswith("/hls/") or path.startswith("/stream/") or (
            path.startswith("/") and path.endswith(".ts")
        ):
            name = path.rsplit("/", 1)[-1]
            if "/" in name or not name.endswith(".ts"):
                self.send_error(404)
                return
            target = current_dir() / name
            if target.exists():
                self.serve_file(target, "video/mp2t")
                return
            self.send_error(404)
            return

        if path.startswith("/videos/"):
            rel = path[len("/videos/"):]
            target = safe_video_path(rel)
            if target and target.exists() and target.is_file():
                mime = "video/mp4" if target.suffix.lower() == ".mp4" else "application/octet-stream"
                self.serve_file(target, mime)
                return
            self.send_error(404)
            return

        if path == "/":
            self.send_json(200, {"service": "HICHRAWI-TV", "ok": True})
            return

        self.send_error(404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/api/source":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length > 5_000_000:
            self.send_error(413)
            return

        try:
            body = self.rfile.read(length)
            request = json.loads(body.decode("utf-8"))
        except Exception:
            self.send_json(400, {"error": "invalid json"})
            return

        # Authentication is verified by stream_engine.py.
        request["_received_from_api"] = True
        CONTROL_FILE.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
        self.send_json(202, {"ok": True, "status": "accepted"})

    def serve_file(self, path, mime):
        try:
            size = path.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.end_headers()
            with path.open("rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except BrokenPipeError:
            pass

    def log_message(self, fmt, *args):
        print("[HLS]", fmt % args, flush=True)

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
