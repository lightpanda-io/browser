from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys


def html(title: str, body: str) -> bytes:
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{title}</title></head><body>{body}</body></html>"
    ).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "IndexedDbSmoke/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))

    def do_GET(self):
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return

        if self.path == "/seed.html":
            body = html(
                "IndexedDB Loading - Lightpanda Browser",
                "<script>"
                "const req=indexedDB.open('lp-persist',1);"
                "req.onupgradeneeded=()=>{req.result.createObjectStore('items');};"
                "req.onerror=()=>{document.title='IndexedDB Seed Error - Lightpanda Browser';};"
                "req.onsuccess=()=>{"
                "const db=req.result;"
                "const tx=db.transaction('items');"
                "const store=tx.objectStore('items');"
                "const putReq=store.put({status:'ok'},'persist');"
                "putReq.onerror=()=>{document.title='IndexedDB Seed Error - Lightpanda Browser';};"
                "putReq.onsuccess=()=>{document.title='IndexedDB Seeded - Lightpanda Browser';};"
                "};"
                "</script><h1>seed</h1>",
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
                "IndexedDB Loading - Lightpanda Browser",
                "<script>"
                "const req=indexedDB.open('lp-persist',1);"
                "req.onupgradeneeded=()=>{document.title='IndexedDB Echo missing - Lightpanda Browser';};"
                "req.onerror=()=>{document.title='IndexedDB Echo missing - Lightpanda Browser';};"
                "req.onsuccess=()=>{"
                "try{"
                "const db=req.result;"
                "const tx=db.transaction('items');"
                "const store=tx.objectStore('items');"
                "const getReq=store.get('persist');"
                "getReq.onerror=()=>{document.title='IndexedDB Echo missing - Lightpanda Browser';};"
                "getReq.onsuccess=()=>{"
                "const value=getReq.result;"
                "document.title=(value&&value.status==='ok'?'IndexedDB Echo ok - Lightpanda Browser':'IndexedDB Echo missing - Lightpanda Browser');"
                "};"
                "}catch(_err){document.title='IndexedDB Echo missing - Lightpanda Browser';}"
                "};"
                "</script><h1>echo</h1>",
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/index-seed.html":
            body = html(
                "IndexedDB Loading - Lightpanda Browser",
                "<script>"
                "const req=indexedDB.open('lp-index-persist',1);"
                "req.onupgradeneeded=()=>{"
                "const store=req.result.createObjectStore('users');"
                "store.createIndex('by_email','email');"
                "};"
                "req.onerror=()=>{document.title='IndexedDB Index Seed Error - Lightpanda Browser';};"
                "req.onsuccess=()=>{"
                "const db=req.result;"
                "const tx=db.transaction('users');"
                "const store=tx.objectStore('users');"
                "const putReq=store.put({status:'ok',email:'ada@example.com'},'user-1');"
                "putReq.onerror=()=>{document.title='IndexedDB Index Seed Error - Lightpanda Browser';};"
                "putReq.onsuccess=()=>{document.title='IndexedDB Index Seeded - Lightpanda Browser';};"
                "};"
                "</script><h1>index-seed</h1>",
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/index-echo.html":
            body = html(
                "IndexedDB Loading - Lightpanda Browser",
                "<script>"
                "const req=indexedDB.open('lp-index-persist',1);"
                "req.onupgradeneeded=()=>{document.title='IndexedDB Index Echo missing - Lightpanda Browser';};"
                "req.onerror=()=>{document.title='IndexedDB Index Echo missing - Lightpanda Browser';};"
                "req.onsuccess=()=>{"
                "try{"
                "const db=req.result;"
                "const tx=db.transaction('users');"
                "const store=tx.objectStore('users');"
                "const index=store.index('by_email');"
                "const getReq=index.get('ada@example.com');"
                "getReq.onerror=()=>{document.title='IndexedDB Index Echo missing - Lightpanda Browser';};"
                "getReq.onsuccess=()=>{"
                "const value=getReq.result;"
                "document.title=(value&&value.status==='ok'&&value.email==='ada@example.com'?'IndexedDB Index Echo ok - Lightpanda Browser':'IndexedDB Index Echo missing - Lightpanda Browser');"
                "};"
                "}catch(_err){document.title='IndexedDB Index Echo missing - Lightpanda Browser';}"
                "};"
                "</script><h1>index-echo</h1>",
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/cursor-seed.html":
            body = html(
                "IndexedDB Loading - Lightpanda Browser",
                "<script>"
                "const req=indexedDB.open('lp-cursor-persist',1);"
                "req.onupgradeneeded=()=>{"
                "const store=req.result.createObjectStore('users');"
                "store.createIndex('by_email','email');"
                "};"
                "req.onerror=()=>{document.title='IndexedDB Cursor Seed Error - Lightpanda Browser';};"
                "req.onsuccess=()=>{"
                "const db=req.result;"
                "const tx=db.transaction('users');"
                "const store=tx.objectStore('users');"
                "Promise.all(["
                "new Promise((resolve,reject)=>{const r=store.put({name:'Grace',email:'grace@example.com'},'user-2'); r.onsuccess=()=>resolve(); r.onerror=()=>reject();}),"
                "new Promise((resolve,reject)=>{const r=store.put({name:'Ada',email:'ada@example.com'},'user-1'); r.onsuccess=()=>resolve(); r.onerror=()=>reject();}),"
                "new Promise((resolve,reject)=>{const r=store.put({name:'Linus',email:'linus@example.com'},'user-3'); r.onsuccess=()=>resolve(); r.onerror=()=>reject();})"
                "]).then(()=>{document.title='IndexedDB Cursor Seeded - Lightpanda Browser';}).catch(()=>{document.title='IndexedDB Cursor Seed Error - Lightpanda Browser';});"
                "};"
                "</script><h1>cursor-seed</h1>",
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/cursor-echo.html":
            body = html(
                "IndexedDB Loading - Lightpanda Browser",
                "<script>"
                "function iterateCursor(request, step){return new Promise((resolve,reject)=>{const rows=[]; request.onerror=()=>reject(); request.onsuccess=()=>{const cursor=request.result; if(!cursor){resolve(rows); return;} rows.push(step(cursor)); cursor.continue();};});}"
                "const req=indexedDB.open('lp-cursor-persist',1);"
                "req.onupgradeneeded=()=>{document.title='IndexedDB Cursor Echo missing - Lightpanda Browser';};"
                "req.onerror=()=>{document.title='IndexedDB Cursor Echo missing - Lightpanda Browser';};"
                "req.onsuccess=()=>{"
                "try{"
                "const db=req.result;"
                "const tx=db.transaction('users');"
                "const store=tx.objectStore('users');"
                "Promise.all(["
                "iterateCursor(store.openCursor(), (cursor)=>`${cursor.primaryKey}:${cursor.value.name}`),"
                "iterateCursor(store.index('by_email').openCursor(), (cursor)=>`${cursor.key}:${cursor.primaryKey}:${cursor.value.name}`)"
                "]).then((rows)=>{"
                "const storeRows=rows[0].join('|');"
                "const indexRows=rows[1].join('|');"
                "const ok=storeRows==='user-1:Ada|user-2:Grace|user-3:Linus'&&indexRows==='ada@example.com:user-1:Ada|grace@example.com:user-2:Grace|linus@example.com:user-3:Linus';"
                "document.title=(ok?'IndexedDB Cursor Echo ok - Lightpanda Browser':'IndexedDB Cursor Echo missing - Lightpanda Browser');"
                "}).catch(()=>{document.title='IndexedDB Cursor Echo missing - Lightpanda Browser';});"
                "}catch(_err){document.title='IndexedDB Cursor Echo missing - Lightpanda Browser';}"
                "};"
                "</script><h1>cursor-echo</h1>",
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
    port = 8210
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
