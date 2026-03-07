import http.server
import sys
from urllib.parse import parse_qs


class PopupFormHandler(http.server.BaseHTTPRequestHandler):
    def _write_html(self, body: bytes, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/ping":
            self._write_html(b"ok")
            return

        if self.path == "/form-post-index.html":
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Popup Form Post Start</title>"
                b"</head><body>"
                b"<main style=\"display:block;padding:24px;\">"
                b"<form action=\"/form-post-result.html\" method=\"post\" target=\"_blank\">"
                b"<input type=\"hidden\" name=\"q\" value=\"popup-post\">"
                b"<input id=\"submitter\" type=\"submit\" value=\"OPEN POST POPUP\" autofocus "
                b"style=\"font-size:30px;width:360px;\">"
                b"</form></main></body></html>"
            )
            self._write_html(body)
            return

        self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/form-post-result.html":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        decoded = raw.decode("utf-8", errors="replace")
        parsed = parse_qs(decoded)
        q = parsed.get("q", [""])[0]
        sys.stderr.write(f"POPUP_POST_BODY {decoded}\n")
        sys.stderr.flush()

        body = (
            "<!doctype html><html><head><meta charset=\"utf-8\">"
            f"<title>Popup Form Post Result {q}</title>"
            "</head><body><main><h1>Popup Form Post Result</h1></main></body></html>"
        ).encode("utf-8")
        self._write_html(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))
        sys.stderr.flush()


def main() -> None:
    port = int(sys.argv[1])
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), PopupFormHandler)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
