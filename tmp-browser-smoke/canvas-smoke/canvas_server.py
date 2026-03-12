import http.server
import os
import socketserver
import sys


ROOT = os.path.dirname(__file__)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8166


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write((fmt % args) + "\n")


socketserver.TCPServer.allow_reuse_address = True

with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
