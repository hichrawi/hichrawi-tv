from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import os

os.chdir("/stream")

class CORSHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin","*")
        super().end_headers()

ThreadingHTTPServer(("0.0.0.0",8080), CORSHandler).serve_forever()
