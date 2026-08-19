from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import os

STREAM_DIR = "/stream"

os.chdir(STREAM_DIR)


class CORSHandler(SimpleHTTPRequestHandler):

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        # رابط M3U ثابت لـ HICHRAWI-TV
        if self.path.split("?")[0] == "/hichrawi.m3u":
            playlist = (
                "#EXTM3U\n"
                '#EXTINF:-1 tvg-name="HICHRAWI TV",HICHRAWI TV\n'
                "/stream.m3u8\n"
            ).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "audio/x-mpegurl")
            self.send_header("Content-Length", str(len(playlist)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(playlist)
            return

        super().do_GET()


server = ThreadingHTTPServer(("0.0.0.0", 8080), CORSHandler)

print("HICHRAWI-TV HLS server running on port 8080")
print("Fixed M3U: /hichrawi.m3u")

server.serve_forever()
