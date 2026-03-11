import base64
import json
import sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent
REQUEST_LOG = ROOT / "font.requests.jsonl"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8162
AUTH_HEADER = "Basic " + base64.b64encode(b"fontuser:p@ss").decode("ascii")
FONT_BYTES = b"dummy-font-bytes-for-shared-runtime-font-tests"


def append_log(entry: dict) -> None:
    with REQUEST_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


def page_body(title: str, link_source: str, crossorigin: str | None, beacon_path: str) -> bytes:
    crossorigin_script = ""
    if crossorigin is not None:
        crossorigin_script = f"link.crossOrigin = {crossorigin!r};"

    body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>{title}</title></head>
<body>
<script>
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  {crossorigin_script}
  link.href = {link_source!r};
  link.onload = async () => {{
    const loaded = await document.fonts.load('16px "Probe Font"');
    const family = getComputedStyle(document.body).getPropertyValue('font-family');
    const sheet = link.sheet instanceof CSSStyleSheet ? 1 : 0;
    const ruleCount = link.sheet ? link.sheet.cssRules.length : 0;
    const check = document.fonts.check('16px "Probe Font"') ? 1 : 0;
    const beacon = new Image();
    beacon.alt = 'font-loaded';
    beacon.src = '{beacon_path}?size=' + document.fonts.size +
      '&status=' + encodeURIComponent(document.fonts.status) +
      '&check=' + check +
      '&loadCount=' + loaded.length +
      '&family=' + encodeURIComponent(family) +
      '&sheet=' + sheet +
      '&rules=' + ruleCount;
    document.body.appendChild(beacon);
  }};
  document.head.appendChild(link);
</script>
</body>
</html>
"""
    return body.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/auth-font-page.html":
            body = page_body("Font Pending", "/private-font.css", None, "/loaded")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpfont=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-font-anonymous-page.html":
            body = page_body(
                "Font Anonymous Pending",
                f"http://fontuser:p%40ss@127.0.0.1:{PORT}/private-font-anonymous.css",
                "anonymous",
                "/loaded-anon",
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpfontanon=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/private-font.css":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-font-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpfont=ok" in cookie
                and referer == expected_referer
                and authorization == AUTH_HEADER
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
                body = b"body { background: rgb(255, 0, 0); }"
                self.send_response(403)
                self.send_header("Content-Type", "text/css; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = (
                '@font-face { font-family: "Probe Font"; src: url("/private-font.woff2"); } '
                'body { font-family: "Probe Font", sans-serif; }'
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/css; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/private-font-anonymous.css":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-font-anonymous-page.html"
            allowed = (
                "Lightpanda/" in ua
                and cookie == ""
                and referer == expected_referer
                and authorization == ""
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
                body = b"body { background: rgb(255, 0, 0); }"
                self.send_response(403)
                self.send_header("Content-Type", "text/css; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = (
                f'@font-face {{ font-family: "Probe Font"; src: url("http://fontuser:p%40ss@127.0.0.1:{PORT}/private-font-anonymous.woff2"); }} '
                'body { font-family: "Probe Font", sans-serif; }'
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/css; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/private-font.woff2":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/private-font.css"
            allowed = (
                "Lightpanda/" in ua
                and "lpfont=ok" in cookie
                and referer == expected_referer
                and authorization == AUTH_HEADER
                and "font/woff2" in accept
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
                body = b"blocked"
                self.send_response(403)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            self.send_response(200)
            self.send_header("Content-Type", "font/woff2")
            self.send_header("Content-Length", str(len(FONT_BYTES)))
            self.end_headers()
            self.wfile.write(FONT_BYTES)
            return

        if self.path == "/private-font-anonymous.woff2":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/private-font-anonymous.css"
            allowed = (
                "Lightpanda/" in ua
                and cookie == ""
                and referer == expected_referer
                and authorization == ""
                and "font/woff2" in accept
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
                body = b"blocked"
                self.send_response(403)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            self.send_response(200)
            self.send_header("Content-Type", "font/woff2")
            self.send_header("Content-Length", str(len(FONT_BYTES)))
            self.end_headers()
            self.wfile.write(FONT_BYTES)
            return

        if self.path.startswith("/loaded"):
            parsed = urlparse(self.path)
            params = parse_qs(parsed.query)
            entry = {
                "path": parsed.path,
                "size": params.get("size", [""])[0],
                "status": params.get("status", [""])[0],
                "check": params.get("check", [""])[0],
                "loadCount": params.get("loadCount", [""])[0],
                "family": params.get("family", [""])[0],
                "sheet": params.get("sheet", [""])[0],
                "rules": params.get("rules", [""])[0],
            }
            entry["allowed"] = (
                entry["size"] == "1"
                and entry["status"] == "loaded"
                and entry["check"] == "1"
                and entry["loadCount"] == "1"
                and "Probe Font" in entry["family"]
                and entry["sheet"] == "1"
                and entry["rules"] == "2"
            )
            append_log(entry)
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        body = b"not found"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:
        return


def main() -> int:
    REQUEST_LOG.write_text("", encoding="utf-8")
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
