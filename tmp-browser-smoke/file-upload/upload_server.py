import html
import os
import sys
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = os.path.dirname(os.path.abspath(__file__))


def html_page(title: str, body: str) -> bytes:
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{html.escape(title)}</title>
</head>
<body>
{body}
</body>
</html>
""".encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write("HTTP " + (format % args) + "\n")
        sys.stderr.flush()

    def do_GET(self):
        if self.path == "/ping":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        if self.path == "/" or self.path == "/upload.html":
            with open(os.path.join(ROOT, "upload.html"), "rb") as handle:
                data = handle.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"not found")

    def do_POST(self):
        if self.path != "/upload":
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"not found")
            return

        note, upload_name, payload = parse_multipart_form(self.headers, self.rfile)
        if not upload_name:
            sys.stderr.write("UPLOAD_EMPTY\n")
            sys.stderr.flush()
            body = html_page("Upload Missing - Lightpanda Browser", "<h1>Upload missing</h1>")
            self.send_response(400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        filename = os.path.basename(upload_name)
        preview = payload.decode("utf-8", "replace").replace("\r", "\\r").replace("\n", "\\n")
        sys.stderr.write(f"UPLOAD filename={filename} note={note} size={len(payload)} payload={preview}\n")
        sys.stderr.flush()

        body = html_page(
            f"Upload Submitted {filename} - Lightpanda Browser",
            f"<h1>Uploaded {html.escape(filename)}</h1><p>{html.escape(note)}</p>",
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def parse_multipart_form(headers, stream):
    content_type = headers.get("Content-Type", "")
    content_length = int(headers.get("Content-Length", "0") or "0")
    raw = stream.read(content_length)
    parser_input = (
        f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode("utf-8") + raw
    )
    message = BytesParser(policy=policy.default).parsebytes(parser_input)
    if not message.is_multipart():
        return "", None, b""

    note = ""
    upload_name = None
    upload_payload = b""

    for part in message.iter_parts():
        disposition = part.get_content_disposition()
        if disposition != "form-data":
            continue
        field_name = part.get_param("name", header="content-disposition")
        filename = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if filename:
            upload_name = filename
            upload_payload = payload
        elif field_name == "note":
            note = payload.decode("utf-8", "replace")

    return note, upload_name, upload_payload


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8162
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write(f"UPLOAD_SERVER_READY {port}\n")
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
