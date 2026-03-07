import http.server
import sys
from urllib.parse import parse_qs, urlparse


class PopupFormHandler(http.server.BaseHTTPRequestHandler):
    def _write_html(self, body: bytes, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/ping":
            self._write_html(b"ok")
            return

        if path == "/form-post-index.html":
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

        if path == "/form-target-get-index.html":
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Popup Named Form Start</title>"
                b"</head><body>"
                b"<main style=\"display:block;padding:24px;\">"
                b"<p style=\"display:block;margin:0 0 18px 0;\">Both submits target the same named popup tab.</p>"
                b"<form action=\"/form-target-result.html\" method=\"get\" target=\"report\" style=\"display:block;margin:0 0 18px 0;\">"
                b"<input type=\"hidden\" name=\"q\" value=\"one\">"
                b"<input id=\"submitter-one\" type=\"submit\" value=\"OPEN FORM RESULT ONE\" autofocus style=\"font-size:30px;width:420px;\">"
                b"</form>"
                b"<form action=\"/form-target-result.html\" method=\"get\" target=\"report\" style=\"display:block;\">"
                b"<input type=\"hidden\" name=\"q\" value=\"two\">"
                b"<input id=\"submitter-two\" type=\"submit\" value=\"OPEN FORM RESULT TWO\" style=\"font-size:30px;width:420px;\">"
                b"</form>"
                b"</main></body></html>"
            )
            self._write_html(body)
            return

        if path == "/form-target-post-index.html":
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Popup Named Form Post Start</title>"
                b"</head><body>"
                b"<main style=\"display:block;padding:24px;\">"
                b"<p style=\"display:block;margin:0 0 18px 0;\">Both submits target the same named popup tab.</p>"
                b"<form action=\"/form-target-post-result.html\" method=\"post\" target=\"report\" style=\"display:block;margin:0 0 18px 0;\">"
                b"<input type=\"hidden\" name=\"q\" value=\"one\">"
                b"<input id=\"submitter-one\" type=\"submit\" value=\"OPEN POST RESULT ONE\" autofocus style=\"font-size:30px;width:420px;\">"
                b"</form>"
                b"<form action=\"/form-target-post-result.html\" method=\"post\" target=\"report\" style=\"display:block;\">"
                b"<input type=\"hidden\" name=\"q\" value=\"two\">"
                b"<input id=\"submitter-two\" type=\"submit\" value=\"OPEN POST RESULT TWO\" style=\"font-size:30px;width:420px;\">"
                b"</form>"
                b"</main></body></html>"
            )
            self._write_html(body)
            return

        if path == "/form-target-result.html":
            q = query.get("q", [""])[0]
            body = (
                "<!doctype html><html><head><meta charset=\"utf-8\">"
                f"<title>Popup Named Form Result {q}</title>"
                "</head><body><main><h1>Popup Named Form Result</h1></main></body></html>"
            ).encode("utf-8")
            self._write_html(body)
            return

        self.send_error(404)

    def do_POST(self) -> None:
        if self.path not in ("/form-post-result.html", "/form-target-post-result.html"):
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        decoded = raw.decode("utf-8", errors="replace")
        parsed = parse_qs(decoded)
        q = parsed.get("q", [""])[0]
        if self.path == "/form-target-post-result.html":
            sys.stderr.write(f"POPUP_TARGET_POST_BODY {decoded}\n")
        else:
            sys.stderr.write(f"POPUP_POST_BODY {decoded}\n")
        sys.stderr.flush()

        if self.path == "/form-target-post-result.html":
            body = (
                "<!doctype html><html><head><meta charset=\"utf-8\">"
                f"<title>Popup Named Form Post Result {q}</title>"
                "</head><body><main><h1>Popup Named Form Post Result</h1></main></body></html>"
            ).encode("utf-8")
        else:
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
