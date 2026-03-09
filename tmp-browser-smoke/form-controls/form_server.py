import http.server
import socketserver
import sys
import urllib.parse


class FormHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ping":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/label.html":
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Label Smoke Base</title>"
                b"</head><body style=\"margin:0;background:white;color:#222;font:22px sans-serif;\">"
                b"<main style=\"display:block;padding:24px;\">"
                b"<p style=\"display:block;margin:0 0 18px 0;\">Click the label to toggle the checkbox.</p>"
                b"<label id=\"agree-label\" for=\"agree\""
                b" style=\"display:block;width:220px;height:40px;padding:10px;background-color:#1a55d6;color:white;\">"
                b"Agree to smoke test</label>"
                b"<input id=\"agree\" type=\"checkbox\""
                b" style=\"display:block;width:24px;height:24px;margin-top:14px;\" />"
                b"<script>"
                b"const checkbox = document.getElementById('agree');"
                b"checkbox.addEventListener('change', function() {"
                b" document.title='Label Smoke '+checkbox.checked;"
                b"});"
                b"</script>"
                b"</main></body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/submit.html":
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\">"
                b"<title>Enter Submit Base</title>"
                b"</head><body style=\"margin:0;background:white;color:#222;font:22px sans-serif;\">"
                b"<main style=\"display:block;padding:24px;\">"
                b"<form action=\"/submitted.html\" method=\"get\" style=\"display:block;\">"
                b"<label for=\"name\" style=\"display:block;margin:0 0 10px 0;\">Name</label>"
                b"<input id=\"name\" name=\"name\" type=\"text\" autofocus"
                b" style=\"display:block;width:220px;height:40px;padding:8px;border:1px solid #666;\" />"
                b"</form>"
                b"<script>"
                b"const nameInput = document.getElementById('name');"
                b"nameInput.addEventListener('input', function() {"
                b" document.title='Enter Submit '+nameInput.value;"
                b"});"
                b"</script>"
                b"</main></body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/submitted.html"):
            sys.stderr.write("FORM_SUBMIT " + self.path + "\n")
            sys.stderr.flush()
            parsed = urllib.parse.urlparse(self.path)
            params = urllib.parse.parse_qs(parsed.query)
            name = params.get("name", [""])[0]
            title = f"Submitted {name}".encode("utf-8")
            body = (
                b"<!doctype html><html><head><meta charset=\"utf-8\"><title>" +
                title +
                b"</title></head><body><h1>Submitted</h1></body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_error(404)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))
        sys.stderr.flush()


def main():
    port = int(sys.argv[1])
    with socketserver.TCPServer(("127.0.0.1", port), FormHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
