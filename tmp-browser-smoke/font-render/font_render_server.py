from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent
REPO_FONT = ROOT.parent.parent / "src" / "browser" / "tests" / "css" / "private_font_test.ttf"
REPO_FONT_WOFF = ROOT.parent.parent / "src" / "browser" / "tests" / "css" / "font_face_test.woff"
REPO_FONT_WOFF2 = ROOT.parent.parent / "src" / "browser" / "tests" / "css" / "font_face_test.woff2"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8163


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_GET(self):
        if self.path == "/private_font_test.ttf":
            data = REPO_FONT.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "font/ttf")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/font_face_test.woff":
            data = REPO_FONT_WOFF.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "font/woff")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/font_face_test.woff2":
            data = REPO_FONT_WOFF2.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "font/woff2")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()
