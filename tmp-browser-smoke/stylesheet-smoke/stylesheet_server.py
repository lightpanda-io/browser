import json
import sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent
REQUEST_LOG = ROOT / "stylesheet.requests.jsonl"
PORT = 8160


def append_log(entry: dict) -> None:
    with REQUEST_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/auth-stylesheet-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Stylesheet Pending</title></head>
<body>
<script>
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = '/private.css';
  link.onload = () => {
    const ok = (link.sheet instanceof CSSStyleSheet) ? 1 : 0;
    const count = document.styleSheets.length;
    const bg = getComputedStyle(document.body).backgroundColor;
    const applied = bg === 'rgb(24, 194, 62)' ? 1 : 0;
    document.title = applied ? 'Stylesheet Applied' : 'Stylesheet Loaded';
    const beacon = new Image();
    beacon.alt = 'stylesheet-loaded';
    beacon.src = '/loaded?sheet=' + ok + '&count=' + count + '&applied=' + applied + '&bg=' + encodeURIComponent(bg);
    document.body.appendChild(beacon);
  };
  document.head.appendChild(link);
</script>
</body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpcss=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/private.css":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-stylesheet-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpcss=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic Y3NzIHVzZXI6cEBzcw=="
                and "text/css" in accept
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
                "accept": accept,
                "allowed": allowed,
            })
            if not allowed:
                body = b"body{background:#ff0000;}"
                self.send_response(403)
                self.send_header("Content-Type", "text/css; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = b"body { background-color: rgb(24, 194, 62); color: white; }"
            self.send_response(200)
            self.send_header("Content-Type", "text/css; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/loaded"):
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            append_log({
                "path": parsed.path,
                "sheet": query.get("sheet", [""])[0],
                "count": query.get("count", [""])[0],
                "applied": query.get("applied", [""])[0],
                "bg": query.get("bg", [""])[0],
                "allowed": (
                    query.get("sheet", ["0"])[0] == "1"
                    and query.get("count", ["0"])[0] != "0"
                    and query.get("applied", ["0"])[0] == "1"
                ),
            })
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
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
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8160
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
