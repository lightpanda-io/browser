from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys


def html(title: str, body: str) -> bytes:
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{title}</title></head><body>{body}</body></html>"
    ).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalStorageSmoke/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))

    def do_GET(self):
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return

        if self.path == "/seed.html":
            body = html(
                "Local Storage Loading - Lightpanda Browser",
                "<script>localStorage.setItem('lppersist','ok');document.title='Local Storage Seeded - Lightpanda Browser';</script><h1>seed</h1>",
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/echo.html":
            body = html(
                "Local Storage Loading - Lightpanda Browser",
                "<script>document.title=(localStorage.getItem('lppersist')==='ok'?'Local Storage Echo ok - Lightpanda Browser':'Local Storage Echo missing - Lightpanda Browser');</script><h1>echo</h1>",
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        body = html("Not Found - Lightpanda Browser", "<h1>Not Found</h1>")
        self.send_response(404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    port = 8200
    if len(sys.argv) > 1:
        port = int(sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
