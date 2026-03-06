import http.server
import socketserver
import sys
import time


class SlowHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ping":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/" or self.path == "/index.html":
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Stop Restore Base</title>"
                b"<script>"
                b"window.__stopRestoreTick=0;"
                b"setInterval(function(){"
                b"window.__stopRestoreTick+=1;"
                b"document.title='Stop Restore Tick '+window.__stopRestoreTick;"
                b"},700);"
                b"</script>"
                b"</head>"
                b"<body style=\"margin:0;background:white;color:#222;font:20px sans-serif;\">"
                b"<main style=\"display:block;padding:24px;\">"
                b"<p style=\"display:block;margin:0 0 20px 0;\">Base page before the slow navigation.</p>"
                b"<p style=\"display:block;margin:0 0 20px 0;color:#1c7c3c;\">"
                b"The page title should keep ticking forward after stop if the live context resumes.</p>"
                b"<p style=\"display:block;margin:0;\">"
                b"<a href=\"/slow.html\" style=\"display:inline;color:#555;text-decoration:none;\">"
                b"<span style=\"display:inline;color:white;background-color:#1a55d6;padding:6px 10px;\">OPEN SLOW</span>"
                b"</a></p>"
                b"</main></body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/input.html":
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Stop Restore Input Base</title>"
                b"</head>"
                b"<body style=\"margin:0;background:white;color:#222;font:20px sans-serif;\">"
                b"<main style=\"display:block;padding:24px;\">"
                b"<p style=\"display:block;margin:0 0 18px 0;\">"
                b"Type into the input, navigate to the slow page, stop, then continue typing.</p>"
                b"<p style=\"display:block;margin:0 0 18px 0;\">"
                b"<input type=\"text\" autofocus"
                b" style=\"display:block;width:160px;padding:8px;border:1px solid #666;\" />"
                b"</p>"
                b"<p style=\"display:block;margin:0;\">"
                b"<a href=\"/slow.html\" style=\"display:inline;color:#555;text-decoration:none;\">"
                b"<span style=\"display:inline;color:white;background-color:#1a55d6;padding:6px 10px;\">OPEN SLOW</span>"
                b"</a></p>"
                b"</main>"
                b"<script>"
                b"const input = document.querySelector('input');"
                b"input.addEventListener('input', () => { document.title = 'Stop Restore Input ' + input.value; });"
                b"input.focus();"
                b"</script>"
                b"</body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/slow.html":
            sys.stderr.write("SLOW_RESPONSE_BEGIN /slow.html\n")
            sys.stderr.flush()
            time.sleep(5)
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Slow Target</title></head><body><h1>Slow Target</h1>"
                b"<p>If this finishes, stop failed.</p></body></html>"
            )
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                sys.stderr.write("SLOW_RESPONSE_SENT /slow.html\n")
                sys.stderr.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                sys.stderr.write("SLOW_RESPONSE_ABORTED /slow.html\n")
                sys.stderr.flush()
            return

        self.send_error(404)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))
        sys.stderr.flush()


def main():
    port = int(sys.argv[1])
    with socketserver.TCPServer(("127.0.0.1", port), SlowHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
