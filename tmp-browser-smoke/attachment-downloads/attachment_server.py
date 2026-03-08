import http.server
import socketserver
import sys
import urllib.parse

PORT = int(sys.argv[1])
COUNTS = {}

INDEX_HTML = """<!doctype html>
<html>
<head>
  <meta charset=\"utf-8\">
  <title>Attachment Download Home</title>
</head>
<body>
  <h1>Attachment Download Home</h1>
  <p><a id=\"basic-link\" style=\"display:inline-block;padding:20px 28px;background:#d8e7ff;border:2px solid #234;font-size:24px\" href=\"/attachment-basic\">Download basic attachment</a></p>
  <p><a id=\"named-link\" style=\"display:inline-block;padding:16px 24px;background:#f1f1f1;border:1px solid #666;font-size:20px\" href=\"/attachment-named\">Download named attachment</a></p>
  <p><a id=\"page-two-link\" href=\"/page-two.html\">Open regular page</a></p>
</body>
</html>
"""

PAGE_TWO = """<!doctype html>
<html>
<head>
  <meta charset=\"utf-8\">
  <title>Attachment Page Two</title>
</head>
<body>
  <p>Page two</p>
</body>
</html>
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        COUNTS[path] = COUNTS.get(path, 0) + 1
        sys.stderr.write(f"GET {path} {COUNTS[path]}\n")
        sys.stderr.flush()

        if path in ("/", "/index.html"):
            body = INDEX_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/page-two.html":
            body = PAGE_TWO.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/attachment-basic":
            body = b"basic attachment body\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition", "attachment")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/attachment-named":
            body = b"named attachment body\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="server-report.txt"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
