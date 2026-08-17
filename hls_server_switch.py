#!/usr/bin/env python3
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import urllib.parse

BASE = Path("/stream")
ACTIVE = BASE / ".active"
MAIN = BASE / "main"
NEXT = BASE / "next"

def active_name():
    try:
        value = ACTIVE.read_text().strip()
        return value if value in ("main", "next") else "main"
    except Exception:
        return "main"

def candidate_paths(name):
    # Playlists must come from the active pipeline.
    if name == "stream.m3u8":
        active = MAIN if active_name() == "main" else NEXT
        return [active / name]

    # Segment requests can arrive late from the previous playlist.
    # Search active first, then the other pipeline, so the old segments remain
    # available briefly after a switch.
    if active_name() == "main":
        return [MAIN / name, NEXT / name]
    return [NEXT / name, MAIN / name]

class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def translate_path(self, path):
        clean = urllib.parse.urlsplit(path).path.lstrip("/")
        # Only expose the HLS files through this server.
        if clean == "":
            return str(BASE)
        for candidate in candidate_paths(clean):
            if candidate.is_file():
                return str(candidate)
        # Return a path in the active directory; SimpleHTTPRequestHandler will
        # produce a normal 404 if the requested segment has expired.
        active = MAIN if active_name() == "main" else NEXT
        return str(active / clean)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
