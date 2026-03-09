import json
import sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path


ROOT = Path(__file__).resolve().parent
REQUEST_LOG = ROOT / "http-runtime.requests.jsonl"
PORT = 8153


def append_log(entry: dict) -> None:
    with REQUEST_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/" or self.path == "/img-page.html":
            body = (ROOT / "img-page.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/policy-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Policy Smoke</title></head>
<body><img src="/policy-red.png" alt="policy test"></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpimg=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            allowed = "Lightpanda/" in ua
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "allowed": allowed,
            })
            if not allowed:
                body = b"blocked"
                self.send_response(403)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/policy-red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            expected_referer = f"http://127.0.0.1:{PORT}/policy-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpimg=ok" in cookie
                and referer == expected_referer
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "allowed": allowed,
            })
            if not allowed:
                body = b"blocked"
                self.send_response(403)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    global PORT
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8153
    PORT = port
    if REQUEST_LOG.exists():
        REQUEST_LOG.unlink()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"READY {port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
