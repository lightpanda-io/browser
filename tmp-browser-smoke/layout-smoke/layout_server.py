import http.server
import socketserver
import sys
from functools import partial
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: layout_server.py <port>", file=sys.stderr)
        return 2

    port = int(sys.argv[1])
    root = Path(__file__).resolve().parent
    handler = partial(http.server.SimpleHTTPRequestHandler, directory=str(root))

    class ReuseServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    with ReuseServer(("127.0.0.1", port), handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    raise SystemExit(main())
