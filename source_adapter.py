#!/usr/bin/env python3
"""
HICHRAWI-TV universal source adapter.

This module resolves a source definition to FFmpeg input arguments.
It intentionally does not bypass geo/authentication restrictions.
"""
from urllib.parse import urlparse
from pathlib import Path

VIDEO_EXT = {".mp4",".mkv",".webm",".mov",".m4v",".avi",".ts",".m2ts"}
AUDIO_EXT = {".mp3",".aac",".m4a",".ogg",".opus",".wav",".flac"}

def kind(source):
    return str(source.get("type","iptv")).lower().strip()

def input_args(source):
    t = kind(source)
    url = str(source.get("url","")).strip()

    if t in ("iptv","hls","m3u8","direct_video","mp4","http_video"):
        if not url:
            raise ValueError("رابط المصدر فارغ")
        return [
            "-reconnect","1",
            "-reconnect_streamed","1",
            "-reconnect_at_eof","1",
            "-reconnect_delay_max","10",
            "-rw_timeout","15000000",
            "-i",url
        ]

    if t in ("m3u","playlist"):
        if not url:
            raise ValueError("رابط M3U فارغ")
        return ["-reconnect","1","-reconnect_streamed","1","-reconnect_at_eof","1",
                "-reconnect_delay_max","10","-rw_timeout","15000000","-i",url]

    if t in ("radio","mp3","aac","audio"):
        if not url:
            raise ValueError("رابط الصوت فارغ")
        return ["-reconnect","1","-reconnect_streamed","1","-reconnect_at_eof","1",
                "-reconnect_delay_max","10","-rw_timeout","15000000","-i",url]

    if t == "rtmp":
        if not url:
            raise ValueError("رابط RTMP فارغ")
        return ["-rw_timeout","15000000","-i",url]

    if t == "rtsp":
        if not url:
            raise ValueError("رابط RTSP فارغ")
        return ["-rtsp_transport","tcp","-rw_timeout","15000000","-i",url]

    raise ValueError("نوع مصدر غير مدعوم: " + t)
