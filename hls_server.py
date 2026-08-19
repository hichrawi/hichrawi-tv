#!/usr/bin/env python3
import json
import os
import posixpath
import urllib.parse
import time
import hashlib
import threading
import urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

STREAM_ROOT = Path("/stream")
VIDEO_ROOT = Path("/app/videos")
STATE_FILE = Path("/app/stream_state.json")
CONTROL_FILE = Path("/app/source_request.json")
FALLBACK_FILE = STREAM_ROOT / "fallback_source.json"
SCHEDULE_FILE = STREAM_ROOT / "schedule.json"
VIEWER_STATS_FILE = STREAM_ROOT / "viewer_stats.json"
LOGO_FILE = STREAM_ROOT / "logo.png"
LOGO_REQUEST_FILE = STREAM_ROOT / "logo_request.json"
VIEWER_LOCK = threading.Lock()
VIEWER_ACTIVE_WINDOW = 30
VIEWER_SESSION_GAP = 15 * 60


def _load_viewer_stats():
    try:
        data = json.loads(VIEWER_STATS_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {"date": time.strftime("%Y-%m-%d"), "total_views": 0, "today_views": 0, "seen_today": {}}

def _save_viewer_stats(data):
    tmp = VIEWER_STATS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(VIEWER_STATS_FILE)

def _client_identity(handler):
    forwarded = handler.headers.get("X-Forwarded-For", "").split(",")[0].strip()
    real = handler.headers.get("X-Real-IP", "").strip()
    ip = forwarded or real or handler.client_address[0]
    ua = handler.headers.get("User-Agent", "")
    return hashlib.sha256((ip + "\n" + ua).encode("utf-8", "ignore")).hexdigest()

def register_viewer(handler):
    now = time.time()
    today = time.strftime("%Y-%m-%d")
    ident = _client_identity(handler)
    with VIEWER_LOCK:
        data = _load_viewer_stats()
        if data.get("date") != today:
            data = {"date": today, "total_views": int(data.get("total_views", 0)), "today_views": 0, "seen_today": {}}
        seen = data.setdefault("seen_today", {})
        last = float(seen.get(ident, 0) or 0)
        if now - last >= VIEWER_SESSION_GAP:
            data["today_views"] = int(data.get("today_views", 0)) + 1
            data["total_views"] = int(data.get("total_views", 0)) + 1
        seen[ident] = now
        cutoff = now - 24 * 60 * 60
        for key, value in list(seen.items()):
            try:
                if float(value) < cutoff:
                    del seen[key]
            except Exception:
                del seen[key]
        _save_viewer_stats(data)
        active_cutoff = now - VIEWER_ACTIVE_WINDOW
        active = sum(1 for value in seen.values() if float(value) >= active_cutoff)
        return {"ok": True, "live_viewers": active, "today_views": int(data.get("today_views", 0)), "total_views": int(data.get("total_views", 0)), "updated_at": now, "active_window_seconds": VIEWER_ACTIVE_WINDOW}

def viewer_stats():
    now = time.time()
    today = time.strftime("%Y-%m-%d")
    with VIEWER_LOCK:
        data = _load_viewer_stats()
        if data.get("date") != today:
            data = {"date": today, "total_views": int(data.get("total_views", 0)), "today_views": 0, "seen_today": {}}
            _save_viewer_stats(data)
        seen = data.setdefault("seen_today", {})
        active_cutoff = now - VIEWER_ACTIVE_WINDOW
        active = sum(1 for value in seen.values() if float(value) >= active_cutoff)
        return {"ok": True, "live_viewers": active, "today_views": int(data.get("today_views", 0)), "total_views": int(data.get("total_views", 0)), "updated_at": now, "active_window_seconds": VIEWER_ACTIVE_WINDOW}

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


def save_logo_from_url(url):
    url = str(url or "").strip()
    if not (url.startswith("https://") or url.startswith("http://")):
        raise ValueError("logo URL must use http/https")
    req = urllib.request.Request(url, headers={"User-Agent":"HICHRAWI-TV/1.0"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = resp.read(5 * 1024 * 1024 + 1)
        if len(data) > 5 * 1024 * 1024:
            raise ValueError("logo too large")
        content_type = (resp.headers.get("Content-Type") or "").lower()
        if content_type and not content_type.startswith("image/"):
            raise ValueError("URL is not an image")
    tmp = LOGO_FILE.with_suffix(".tmp")
    tmp.write_bytes(data)
    tmp.replace(LOGO_FILE)
    LOGO_REQUEST_FILE.write_text(json.dumps({"updated_at":time.time()}, ensure_ascii=False), encoding="utf-8")

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
                data = {}
            try:
                state = json.loads(STATE_FILE.read_text())
            except Exception:
                state = {"status": "unknown"}
            self.send_json(200, {"request": data, "state": state})
            return

        if path == "/api/fallback":
            try:
                fallback = json.loads(FALLBACK_FILE.read_text())
            except Exception:
                fallback = {}
            self.send_json(200, {"configured": bool(fallback), "fallback": fallback})
            return

        if path == "/api/schedule":
            try:
                schedule = json.loads(SCHEDULE_FILE.read_text(encoding="utf-8"))
            except Exception:
                schedule = {"enabled": False, "timezone_offset_minutes": 0, "items": []}
            self.send_json(200, schedule)
            return

        if path == "/api/viewers":
            self.send_json(200, viewer_stats())
            return

        if path == "/api/status":
            try:
                state = json.loads(STATE_FILE.read_text())
            except Exception:
                state = {"status": "starting"}
            self.send_json(200, state)
            return

        if path in ("/stream.m3u8", "/stream/stream.m3u8"):
            base = current_dir()
            target = base / "stream.m3u8"
            if not target.exists():
                self.send_json(503, {"error": "stream not ready"})
                return
            register_viewer(self)
            self.serve_file(target, "application/vnd.apple.mpegurl")
            return

        # HLS segments: accept absolute/root segment URLs such as
        # /stream0.ts as well as /stream/stream0.ts and /hls/stream0.ts.
        # This is important because the playlist contains relative names
        # like "stream0.ts", and IPTV players may resolve them against the
        # playlist URL in different ways.
        if path.startswith("/hls/") or path.startswith("/stream/") or (
            path.startswith("/") and path.endswith(".ts")
        ):
            name = path.rsplit("/", 1)[-1]

            if "/" in name or not name.endswith(".ts"):
                self.send_error(404)
                return

            # Prefer the active source directory, then fall back to /stream/.
            target = current_dir() / name
            if not target.exists():
                target = STREAM_ROOT / name

            if target.exists() and target.is_file():
                register_viewer(self)
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
        if parsed.path not in ("/api/source", "/api/fallback", "/api/schedule", "/api/logo"):
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

        # Authentication is verified by the surrounding deployment/auth layer.
        if parsed.path == "/api/logo":
            try:
                url = request.get("url", "")
                save_logo_from_url(url)
                print("[HLS] LOGO UPDATED", flush=True)
                self.send_json(202, {"ok": True, "status": "saved", "message": "logo saved"})
            except Exception as e:
                self.send_json(400, {"ok": False, "error": str(e)})
            return

        if parsed.path == "/api/schedule":
            if not isinstance(request, dict):
                self.send_json(400, {"error": "invalid schedule"})
                return
            items = request.get("items", [])
            if not isinstance(items, list):
                self.send_json(400, {"error": "schedule items must be a list"})
                return
            clean = {
                "enabled": bool(request.get("enabled", True)),
                "timezone_offset_minutes": int(request.get("timezone_offset_minutes", 0)),
                "items": items,
                "updated_at": time.time()
            }
            SCHEDULE_FILE.write_text(json.dumps(clean, ensure_ascii=False), encoding="utf-8")
            print("[HLS] SCHEDULE SAVED: " + json.dumps(clean, ensure_ascii=False), flush=True)
            self.send_json(202, {"ok": True, "status": "saved", "message": "schedule saved"})
            return

        if parsed.path == "/api/fallback":
            if request.get("enabled") is False:
                try:
                    FALLBACK_FILE.unlink()
                except FileNotFoundError:
                    pass
                print("[HLS] FALLBACK SOURCE CLEARED", flush=True)
                self.send_json(202, {"ok": True, "status": "cleared", "message": "fallback source cleared"})
                return
            request["_received_from_api"] = True
            request["_received_at"] = time.time()
            FALLBACK_FILE.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
            print("[HLS] FALLBACK SOURCE SAVED: " + json.dumps(request, ensure_ascii=False), flush=True)
            self.send_json(202, {"ok": True, "status": "saved", "message": "fallback source saved"})
            return

        request["_received_from_api"] = True
        request["_received_at"] = time.time()
        CONTROL_FILE.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
        print("[HLS] SOURCE REQUEST RECEIVED: " + json.dumps(request, ensure_ascii=False), flush=True)
        self.send_json(202, {"ok": True, "status": "accepted", "message": "source request received"})

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

PORT = int(os.environ.get("PORT", 8080))
print(f"[HLS] HTTP server listening on 0.0.0.0:{PORT}", flush=True)
ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
