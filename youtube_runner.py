#!/usr/bin/env python3
import os
import subprocess
import sys

url = sys.argv[1] if len(sys.argv) > 1 else ""

if not url:
    print("YouTube URL missing", file=sys.stderr)
    sys.exit(2)

cookies_file = "/stream/youtube_cookies.txt"

cmd = [
    "yt-dlp",
    "--no-warnings",
    "--no-playlist",
    "-f", "best[protocol^=http][ext=mp4]/best[ext=mp4]/best",
]

# استعمال Cookies إذا الملف موجود
if os.path.isfile(cookies_file):
    cmd += [
        "--cookies",
        cookies_file
    ]
    print("YOUTUBE: Using cookies file.", file=sys.stderr)
else:
    print(
        "YOUTUBE: Cookies file not found: " + cookies_file,
        file=sys.stderr
    )

cmd += [
    "-g",
    url
]

p = subprocess.run(
    cmd,
    text=True,
    capture_output=True
)

if p.returncode != 0:
    print(p.stderr.strip(), file=sys.stderr)
    sys.exit(p.returncode)

lines = [
    line.strip()
    for line in p.stdout.splitlines()
    if line.strip()
]

if not lines:
    print("YouTube direct URL not found", file=sys.stderr)
    sys.exit(1)

print(lines[0])
