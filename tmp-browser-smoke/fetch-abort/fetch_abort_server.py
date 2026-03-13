from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
import time


PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8463


def html(title: str, body: str) -> bytes:
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{title}</title></head><body>{body}</body></html>"
    ).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "FetchAbortSmoke/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))

    def _write_bytes(self, status: int, body: bytes, content_type: str = "text/html; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._write_bytes(200, b"ok", "text/plain; charset=utf-8")
            return

        if self.path == "/page.html":
            body = html(
                "Fetch Abort Loading - Lightpanda Browser",
                """
<script>
(async () => {
  const controller = new AbortController();
  setTimeout(() => controller.abort("probe abort"), 150);
  try {
    await fetch('/slow', { signal: controller.signal });
    document.title = 'Fetch Abort Failed - Lightpanda Browser';
  } catch (err) {
    document.title = err && err.name === 'AbortError'
      ? 'Fetch Abort Ready - Lightpanda Browser'
      : 'Fetch Abort Wrong Error - Lightpanda Browser';
    document.body.setAttribute('data-error-name', err && err.name ? err.name : '');
  }
})().catch((err) => {
  document.title = 'Fetch Abort Script Error - Lightpanda Browser';
  document.body.setAttribute('data-error', String(err));
});
</script>
<h1>fetch abort</h1>
""",
            )
            self._write_bytes(200, body)
            return

        if self.path == "/slow":
            sys.stderr.write("SLOW_START\n")
            chunk = b"x" * 256
            chunk_count = 64
            total_len = len(chunk) * chunk_count
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(total_len))
            self.end_headers()
            try:
                for _ in range(chunk_count):
                    time.sleep(0.1)
                    self.wfile.write(chunk)
                    self.wfile.flush()
                sys.stderr.write("SLOW_COMPLETE\n")
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                sys.stderr.write("SLOW_ABORTED\n")
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
