from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8423
PEER_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else PORT + 1
EXPECTED_AUTH = "Basic ZmV0Y2ggdXNlcjpwQHNz"


def html(title: str, body: str) -> bytes:
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{title}</title></head><body>{body}</body></html>"
    ).encode("utf-8")


def cookie_value(headers):
    raw = headers.get("Cookie", "")
    for part in raw.split(";"):
        part = part.strip()
        if part.startswith("lpfetch="):
            return part.split("=", 1)[1]
    return ""


class Handler(BaseHTTPRequestHandler):
    server_version = "FetchCredentialsSmoke/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))

    def _write_bytes(self, status: int, body: bytes, content_type: str = "text/html; charset=utf-8", cors: bool = False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        if cors:
            self.send_header("Access-Control-Allow-Origin", f"http://127.0.0.1:{PORT}")
            self.send_header("Access-Control-Allow-Credentials", "true")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/healthz":
            self._write_bytes(200, b"ok", "text/plain; charset=utf-8")
            return

        if path == "/page.html":
            body = html(
                "Fetch Credentials Loading - Lightpanda Browser",
                f"""
<script>
(async () => {{
  document.cookie = 'lpfetch=ok; path=/';
  const results = {{}};
  results.sameDefault = await (await fetch('/echo?case=same-default')).json();
  results.sameOmit = await (await fetch('/echo?case=same-omit', {{ credentials: 'omit' }})).json();
  results.crossSame = await (await fetch('http://127.0.0.1:{PEER_PORT}/echo?case=cross-same', {{ credentials: 'same-origin' }})).json();
  results.crossInclude = await (await fetch('http://127.0.0.1:{PEER_PORT}/echo?case=cross-include', {{ credentials: 'include' }})).json();
  const ok =
    results.sameDefault.allowed &&
    results.sameOmit.allowed &&
    results.crossSame.allowed &&
    results.crossInclude.allowed;
  document.title = ok ? 'Fetch Credentials Ready - Lightpanda Browser' : 'Fetch Credentials Failed - Lightpanda Browser';
}})().catch((err) => {{
  document.title = 'Fetch Credentials Error - Lightpanda Browser';
  document.body.setAttribute('data-error', String(err));
}});
</script>
<h1>fetch credentials</h1>
""",
            )
            self._write_bytes(200, body)
            return

        if path == "/echo":
            case = query.get("case", [""])[0]
            headers = self.headers
            referer = headers.get("Referer", "")
            authorization = headers.get("Authorization", "")
            cookie = cookie_value(headers)
            expected_page_port = PORT
            if case.startswith("cross-"):
                expected_page_port = PEER_PORT
            expected_referer = f"http://127.0.0.1:{expected_page_port}/page.html"
            allowed = False
            if case == "same-default":
                allowed = (cookie == "ok" and authorization == EXPECTED_AUTH and referer == expected_referer)
            elif case == "same-omit":
                allowed = (cookie == "" and authorization == "" and referer == expected_referer)
            elif case == "cross-same":
                allowed = (cookie == "" and authorization == "" and referer == expected_referer)
            elif case == "cross-include":
                allowed = (cookie == "ok" and authorization == "" and referer == expected_referer)
            sys.stderr.write(
                json.dumps({
                    "case": case,
                    "cookie": cookie,
                    "authorization": authorization,
                    "referer": referer,
                    "allowed": allowed,
                    "port": self.server.server_port,
                }) + "\n"
            )
            body = json.dumps({
                "case": case,
                "cookie": cookie,
                "authorization": authorization,
                "referer": referer,
                "allowed": allowed,
            }).encode("utf-8")
            self._write_bytes(200, body, "application/json; charset=utf-8", cors=(self.server.server_port == PEER_PORT or PORT != PEER_PORT))
            return

        self._write_bytes(404, html("Not Found - Lightpanda Browser", "<h1>Not Found</h1>"))


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
