import base64
import hashlib
import os
import socketserver
import sys
import urllib.parse


ROOT = os.path.dirname(__file__)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8172
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_until(sock, marker):
    data = b""
    while marker not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        data += chunk
        if len(data) > 65536:
            return None
    return data


def read_frame(sock, initial):
    data = initial
    while len(data) < 2:
        chunk = sock.recv(4096)
        if not chunk:
            return None, b""
        data += chunk

    b1, b2 = data[0], data[1]
    opcode = b1 & 0x0F
    masked = (b2 & 0x80) != 0
    length = b2 & 0x7F
    offset = 2

    if length == 126:
        while len(data) < offset + 2:
            chunk = sock.recv(4096)
            if not chunk:
                return None, b""
            data += chunk
        length = int.from_bytes(data[offset:offset + 2], "big")
        offset += 2
    elif length == 127:
        while len(data) < offset + 8:
            chunk = sock.recv(4096)
            if not chunk:
                return None, b""
            data += chunk
        length = int.from_bytes(data[offset:offset + 8], "big")
        offset += 8

    mask = b""
    if masked:
        while len(data) < offset + 4:
            chunk = sock.recv(4096)
            if not chunk:
                return None, b""
            data += chunk
        mask = data[offset:offset + 4]
        offset += 4

    while len(data) < offset + length:
        chunk = sock.recv(4096)
        if not chunk:
            return None, b""
        data += chunk

    payload = bytearray(data[offset:offset + length])
    if masked:
        for i in range(length):
            payload[i] ^= mask[i % 4]

    return (opcode, bytes(payload)), data[offset + length:]


def send_frame(sock, opcode, payload):
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length <= 125:
        header.append(length)
    elif length <= 0xFFFF:
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(length.to_bytes(8, "big"))
    sock.sendall(bytes(header) + payload)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        raw = recv_until(self.request, b"\r\n\r\n")
        if not raw:
            return

        header_block, remainder = raw.split(b"\r\n\r\n", 1)
        lines = header_block.decode("iso-8859-1").split("\r\n")
        if not lines:
            return

        parts = lines[0].split(" ")
        if len(parts) < 2:
            return

        method = parts[0]
        raw_path = parts[1]
        path = urllib.parse.urlsplit(raw_path).path
        headers = {}
        for line in lines[1:]:
            if ":" not in line:
                continue
            name, value = line.split(":", 1)
            headers[name.strip().lower()] = value.strip()

        if headers.get("upgrade", "").lower() == "websocket" and path == "/echo":
            self.handle_websocket(headers, remainder)
            return

        if method != "GET":
            self.send_response(405, b"Method Not Allowed", b"text/plain; charset=utf-8")
            return

        if path in ("/", "/index.html"):
            with open(os.path.join(ROOT, "index.html"), "rb") as fh:
                body = fh.read()
            self.send_response(200, body, b"text/html; charset=utf-8")
            return

        self.send_response(404, b"Not Found", b"text/plain; charset=utf-8")

    def send_response(self, status, body, content_type):
        reason = {
            200: "OK",
            404: "Not Found",
            405: "Method Not Allowed",
        }.get(status, "OK")
        head = (
            f"HTTP/1.1 {status} {reason}\r\n"
            f"Content-Length: {len(body)}\r\n"
            f"Content-Type: {content_type.decode('ascii')}\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode("ascii")
        self.request.sendall(head + body)

    def handle_websocket(self, headers, remainder):
        key = headers.get("sec-websocket-key")
        if not key:
            return

        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        ).encode("ascii")
        self.request.sendall(response)

        pending = remainder
        while True:
            frame, pending = read_frame(self.request, pending)
            if frame is None:
                return
            opcode, payload = frame
            if opcode == 0x8:
                try:
                    send_frame(self.request, 0x8, payload)
                except OSError:
                    pass
                return
            if opcode == 0x9:
                send_frame(self.request, 0xA, payload)
                continue
            if opcode == 0x1:
                if payload == b"close-me":
                    close_payload = (4001).to_bytes(2, "big") + b"server-close"
                    send_frame(self.request, 0x8, close_payload)
                    return
                send_frame(self.request, 0x1, b"echo:" + payload)
                continue
            if opcode == 0x2:
                send_frame(self.request, 0x2, payload)


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


with ThreadingTCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
