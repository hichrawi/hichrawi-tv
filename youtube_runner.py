#!/usr/bin/env python3
import json, os, subprocess, sys

url = sys.argv[1] if len(sys.argv) > 1 else ""
if not url:
    print("YouTube URL missing", file=sys.stderr)
    sys.exit(2)

cmd = [
    "yt-dlp",
    "--no-warnings",
    "--no-playlist",
    "-f", "best[protocol^=http][ext=mp4]/best[ext=mp4]/best",
    "-g", url
]
p = subprocess.run(cmd, text=True, capture_output=True)
if p.returncode != 0:
    print(p.stderr.strip(), file=sys.stderr)
    sys.exit(p.returncode)
print(p.stdout.strip().splitlines()[0])
