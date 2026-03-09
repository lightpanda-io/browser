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

        if self.path == "/redirect-policy-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Redirect Policy Smoke</title></head>
<body><img src="/redirect-one.png" alt="redirect policy test"></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "page=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-page.html":
            body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Auth Policy Smoke</title></head>
<body><img src="http://img%20user:p%40ss@127.0.0.1:{PORT}/auth-red.png" alt="auth policy test"></body>
</html>
""".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpimgauth=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-anon-page.html":
            body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Auth Anonymous Smoke</title></head>
<body><img crossorigin="anonymous" src="http://img%20user:p%40ss@127.0.0.1:{PORT}/auth-anon-red.png" alt="auth anonymous policy test"></body>
</html>
""".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpimganon=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/accept-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Accept Policy Smoke</title></head>
<body><img src="/accept-red.png" alt="accept policy test"></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
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

        if self.path == "/redirect-one.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "allowed": "Lightpanda/" in ua and "page=ok" in cookie,
            })
            self.send_response(302)
            self.send_header("Location", "/redirect-final.png")
            self.send_header("Set-Cookie", "redirect=ok; Path=/")
            self.end_headers()
            return

        if self.path == "/redirect-final.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            allowed = (
                "Lightpanda/" in ua
                and "page=ok" in cookie
                and "redirect=ok" in cookie
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

        if self.path == "/auth-red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpimgauth=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

        if self.path == "/auth-anon-red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-anon-page.html"
            allowed = (
                "Lightpanda/" in ua
                and cookie == ""
                and referer == expected_referer
                and authorization == ""
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

        if self.path == "/accept-red.png":
            ua = self.headers.get("User-Agent", "")
            accept = self.headers.get("Accept", "")
            referer = self.headers.get("Referer", "")
            expected_referer = f"http://127.0.0.1:{PORT}/accept-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "image/avif" in accept
                and "image/webp" in accept
                and "image/*" in accept
                and "*/*;q=0.8" in accept
                and referer == expected_referer
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "accept": accept,
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
