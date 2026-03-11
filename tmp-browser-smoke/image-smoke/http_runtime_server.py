import json
import sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path


ROOT = Path(__file__).resolve().parent
REQUEST_LOG = ROOT / "http-runtime.requests.jsonl"
PORT = 8153


def append_log(entry: dict) -> None:
    with REQUEST_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/" or self.path == "/img-page.html":
            body = (ROOT / "img-page.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/policy-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Policy Smoke</title></head>
<body><img src="/policy-red.png" alt="policy test"></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpimg=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/redirect-policy-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Redirect Policy Smoke</title></head>
<body><img src="/redirect-one.png" alt="redirect policy test"></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "page=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-page.html":
            body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Auth Policy Smoke</title></head>
<body><img src="http://img%20user:p%40ss@127.0.0.1:{PORT}/auth-red.png" alt="auth policy test"></body>
</html>
""".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpimgauth=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-anon-page.html":
            body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Auth Anonymous Smoke</title></head>
<body><img crossorigin="anonymous" src="http://img%20user:p%40ss@127.0.0.1:{PORT}/auth-anon-red.png" alt="auth anonymous policy test"></body>
</html>
""".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpimganon=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-inherit-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Inherited Auth Smoke</title></head>
<body><img src="/auth-inherit-red.png" alt="inherited auth policy test"></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpimgauthinherit=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-script-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Script Auth Smoke</title></head>
<body><script src="/auth-inherit-script.js"></script></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpscriptauth=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-script-anonymous-page.html":
            body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Script Anonymous Smoke</title></head>
<body><script crossorigin="anonymous" src="http://img%20user:p%40ss@127.0.0.1:{PORT}/auth-anon-script.js"></script></body>
</html>
""".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpscriptanon=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-module-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Module Auth Smoke</title></head>
<body><script type="module" src="/auth-module-root.js"></script></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpmoduleauth=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-module-anonymous-page.html":
            body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Module Anonymous Smoke</title></head>
<body><script type="module" crossorigin="anonymous" src="http://img%20user:p%40ss@127.0.0.1:{PORT}/auth-module-anon-root.js"></script></body>
</html>
""".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "lpmoduleanon=ok; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/accept-page.html":
            body = b"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>Image Accept Policy Smoke</title></head>
<body><img src="/accept-red.png" alt="accept policy test"></body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            allowed = "Lightpanda/" in ua
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/policy-red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            expected_referer = f"http://127.0.0.1:{PORT}/policy-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpimg=ok" in cookie
                and referer == expected_referer
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/redirect-one.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "allowed": "Lightpanda/" in ua and "page=ok" in cookie,
            })
            self.send_response(302)
            self.send_header("Location", "/redirect-final.png")
            self.send_header("Set-Cookie", "redirect=ok; Path=/")
            self.end_headers()
            return

        if self.path == "/redirect-final.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            allowed = (
                "Lightpanda/" in ua
                and "page=ok" in cookie
                and "redirect=ok" in cookie
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpimgauth=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-anon-red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-anon-page.html"
            allowed = (
                "Lightpanda/" in ua
                and cookie == ""
                and referer == expected_referer
                and authorization == ""
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/accept-red.png":
            ua = self.headers.get("User-Agent", "")
            accept = self.headers.get("Accept", "")
            referer = self.headers.get("Referer", "")
            expected_referer = f"http://127.0.0.1:{PORT}/accept-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "image/avif" in accept
                and "image/webp" in accept
                and "image/*" in accept
                and "*/*;q=0.8" in accept
                and referer == expected_referer
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "accept": accept,
                "referer": referer,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-inherit-red.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-inherit-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpimgauthinherit=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-inherit-script.js":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-script-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpscriptauth=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
                "allowed": allowed,
            })
            if not allowed:
                body = b"document.title='Script Auth Blocked';"
                self.send_response(403)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = b"""document.title='Script Auth OK';(function(){var panel=document.createElement('div');panel.id='script-auth-panel';panel.textContent='script auth ok';panel.setAttribute('style','width:320px;height:160px;background:#18c23e;color:#ffffff;padding:24px;font-size:28px;');document.body.innerHTML='';document.body.appendChild(panel);var img=new Image();img.alt='script beacon';img.src='/script-beacon.png';document.body.appendChild(img);}());"""
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-anon-script.js":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-script-anonymous-page.html"
            allowed = (
                "Lightpanda/" in ua
                and cookie == ""
                and referer == expected_referer
                and authorization == ""
                and "*/*" in accept
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
                body = b"document.title='Script Anonymous Blocked';"
                self.send_response(403)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = b"""document.title='Script Anonymous OK';(function(){var panel=document.createElement('div');panel.id='script-auth-anon-panel';panel.textContent='script anonymous ok';panel.setAttribute('style','width:320px;height:160px;background:#147ad6;color:#ffffff;padding:24px;font-size:28px;');document.body.innerHTML='';document.body.appendChild(panel);var img=new Image();img.alt='script anonymous beacon';img.src='/script-anon-beacon.png';document.body.appendChild(img);}());"""
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-module-root.js":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-module-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpmoduleauth=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
                and "*/*" in accept
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
                body = b"throw new Error('blocked root module');"
                self.send_response(403)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = b"import { mountModuleAuth } from './auth-module-child.js'; mountModuleAuth();"
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-module-child.js":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-module-root.js"
            allowed = (
                "Lightpanda/" in ua
                and "lpmoduleauth=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
                and "*/*" in accept
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
                body = b"throw new Error('blocked child module');"
                self.send_response(403)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = b"""export function mountModuleAuth(){document.title='Module Auth OK';var panel=document.createElement('div');panel.id='module-auth-panel';panel.textContent='module auth ok';panel.setAttribute('style','width:320px;height:160px;background:#18c23e;color:#ffffff;padding:24px;font-size:28px;');document.body.innerHTML='';document.body.appendChild(panel);var img=new Image();img.alt='module auth beacon';img.src='/module-auth-beacon.png';document.body.appendChild(img);}"""
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-module-anon-root.js":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-module-anonymous-page.html"
            allowed = (
                "Lightpanda/" in ua
                and cookie == ""
                and referer == expected_referer
                and authorization == ""
                and "*/*" in accept
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
                body = b"throw new Error('blocked anonymous root module');"
                self.send_response(403)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = b"import { mountModuleAnonymous } from './auth-module-anon-child.js'; mountModuleAnonymous();"
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/auth-module-anon-child.js":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            accept = self.headers.get("Accept", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-module-anon-root.js"
            allowed = (
                "Lightpanda/" in ua
                and cookie == ""
                and referer == expected_referer
                and authorization == ""
                and "*/*" in accept
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
                body = b"throw new Error('blocked anonymous child module');"
                self.send_response(403)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            body = b"""export function mountModuleAnonymous(){document.title='Module Anonymous OK';var panel=document.createElement('div');panel.id='module-anon-panel';panel.textContent='module anonymous ok';panel.setAttribute('style','width:320px;height:160px;background:#147ad6;color:#ffffff;padding:24px;font-size:28px;');document.body.innerHTML='';document.body.appendChild(panel);var img=new Image();img.alt='module anonymous beacon';img.src='/module-anon-beacon.png';document.body.appendChild(img);}"""
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/script-beacon.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-script-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpscriptauth=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/script-anon-beacon.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-script-anonymous-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpscriptanon=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/module-auth-beacon.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-module-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpmoduleauth=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/module-anon-beacon.png":
            ua = self.headers.get("User-Agent", "")
            cookie = self.headers.get("Cookie", "")
            referer = self.headers.get("Referer", "")
            authorization = self.headers.get("Authorization", "")
            expected_referer = f"http://127.0.0.1:{PORT}/auth-module-anonymous-page.html"
            allowed = (
                "Lightpanda/" in ua
                and "lpmoduleanon=ok" in cookie
                and referer == expected_referer
                and authorization == "Basic aW1nIHVzZXI6cEBzcw=="
            )
            append_log({
                "path": self.path,
                "user_agent": ua,
                "cookie": cookie,
                "referer": referer,
                "authorization": authorization,
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

            body = (ROOT / "red.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    global PORT
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8153
    PORT = port
    if REQUEST_LOG.exists():
        REQUEST_LOG.unlink()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"READY {port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
