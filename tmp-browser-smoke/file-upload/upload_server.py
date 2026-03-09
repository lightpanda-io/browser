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
    @staticmethod
    def _fixture_path(path: str) -> str | None:
        if path in ("/", "/upload.html"):
            return os.path.join(ROOT, "upload.html")
        if path == "/upload-multiple.html":
            return os.path.join(ROOT, "upload-multiple.html")
        if path == "/upload-target.html":
            return os.path.join(ROOT, "upload-target.html")
        if path == "/upload-attachment.html":
            return os.path.join(ROOT, "upload-attachment.html")
        if path == "/upload-target-attachment.html":
            return os.path.join(ROOT, "upload-target-attachment.html")
        return None

    def _write_fixture(self, path: str) -> bool:
        fixture = self._fixture_path(path)
        if not fixture:
            return False
        with open(fixture, "rb") as handle:
            data = handle.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        return True

    def _write_html_response(self, status: int, title: str, body: str) -> None:
        data = html_page(title, body)
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _write_attachment_response(self, filename: str, payload: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

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

        if self._write_fixture(self.path):
            return

        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"not found")

    def do_POST(self):
        if self.path not in (
            "/upload",
            "/upload-target",
            "/upload-attachment",
            "/upload-target-attachment",
        ):
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"not found")
            return

        note, uploads = parse_multipart_form(self.headers, self.rfile)
        if not uploads:
            sys.stderr.write("UPLOAD_EMPTY\n")
            sys.stderr.flush()
            self._write_html_response(400, "Upload Missing - Lightpanda Browser", "<h1>Upload missing</h1>")
            return

        first_filename = os.path.basename(uploads[0][0])
        summaries = []
        for upload_name, payload in uploads:
            filename = os.path.basename(upload_name)
            preview = payload.decode("utf-8", "replace").replace("\r", "\\r").replace("\n", "\\n")
            summaries.append(f"{filename}:{len(payload)}:{preview}")
        summary = " | ".join(summaries)
        if self.path == "/upload":
            sys.stderr.write(f"UPLOAD files={len(uploads)} note={note} entries={summary}\n")
        elif self.path == "/upload-target":
            sys.stderr.write(f"UPLOAD_TARGET files={len(uploads)} note={note} entries={summary}\n")
        elif self.path == "/upload-attachment":
            sys.stderr.write(f"UPLOAD_ATTACHMENT files={len(uploads)} note={note} entries={summary}\n")
        else:
            sys.stderr.write(f"UPLOAD_TARGET_ATTACHMENT files={len(uploads)} note={note} entries={summary}\n")
        sys.stderr.flush()

        if self.path == "/upload":
            self._write_html_response(
                200,
                f"Upload Submitted {first_filename} - Lightpanda Browser",
                f"<h1>Uploaded {html.escape(first_filename)}</h1><p>{html.escape(note)}</p>",
            )
            return

        if self.path == "/upload-target":
            self._write_html_response(
                200,
                f"Upload Target Submitted {first_filename} - Lightpanda Browser",
                f"<h1>Uploaded {html.escape(first_filename)} in target tab</h1><p>{html.escape(note)}</p>",
            )
            return

        attachment_name = f"uploaded-{first_filename}"
        attachment_payload = uploads[0][1] if uploads[0][1] else first_filename.encode("utf-8")
        self._write_attachment_response(attachment_name, attachment_payload)


def parse_multipart_form(headers, stream):
    content_type = headers.get("Content-Type", "")
    content_length = int(headers.get("Content-Length", "0") or "0")
    raw = stream.read(content_length)
    parser_input = (
        f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode("utf-8") + raw
    )
    message = BytesParser(policy=policy.default).parsebytes(parser_input)
    if not message.is_multipart():
        return "", []

    note = ""
    uploads = []

    for part in message.iter_parts():
        disposition = part.get_content_disposition()
        if disposition != "form-data":
            continue
        field_name = part.get_param("name", header="content-disposition")
        filename = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if filename:
            uploads.append((filename, payload))
        elif field_name == "note":
            note = payload.decode("utf-8", "replace")

    return note, uploads


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
