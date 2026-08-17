# HICHRAWI-TV FINAL V2

Supported sources:
- IPTV / HLS / M3U8
- M3U playlist URL
- Direct MP4/video URL
- Radio / MP3 / AAC (audio is preserved with a black video canvas)
- RTMP
- RTSP over TCP
- YouTube URL (resolved by yt-dlp)
- Local video playlists in /app/videos

Safe switching:
The engine prepares a new source in an inactive HLS directory first. It switches only after the new playlist has valid segments. If preparation fails, the current source remains active.

Important:
Use only streams/media you are authorized to rebroadcast.
