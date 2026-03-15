import http.server
import socketserver
import sys
import time
import struct
import zlib
from functools import partial
from pathlib import Path


def png_chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack("!I", len(data))
        + tag
        + data
        + struct.pack("!I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def make_red_png() -> bytes:
    width = 1
    height = 1
    raw_scanlines = b"\x00" + bytes((220, 50, 50, 255))
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw_scanlines))
        + png_chunk(b"IEND", b"")
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: layout_server.py <port>", file=sys.stderr)
        return 2

    port = int(sys.argv[1])
    root = Path(__file__).resolve().parent
    red_png = make_red_png()

    class LayoutHandler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(root), **kwargs)

        def do_GET(self):
            if self.path == "/slow-ready.png":
                time.sleep(1.0)
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(red_png)))
                self.end_headers()
                self.wfile.write(red_png)
                return
            return super().do_GET()

    class ReuseServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    with ReuseServer(("127.0.0.1", port), LayoutHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    raise SystemExit(main())
