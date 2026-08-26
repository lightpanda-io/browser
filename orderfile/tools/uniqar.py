#!/usr/bin/env python3
# usage: uniqar.py in.a workdir out.a  -- rename sections in every member (see uniqsec.py)
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uniqsec
src, work, out = sys.argv[1:4]
data = open(src, "rb").read()
assert data[:8] == b"!<arch>\n"
pos = 8; longnames = b""; members = []
while pos + 60 <= len(data):
    hdr = data[pos:pos + 60]
    name = hdr[:16].decode().rstrip(); size = int(hdr[48:58])
    body = data[pos + 60:pos + 60 + size]
    if name == "/":
        pass
    elif name == "//":
        longnames = body
    else:
        if name.startswith("/"):
            off = int(name[1:]); end = longnames.index(b"/\n", off); name = longnames[off:end].decode()
        else:
            name = name.rstrip("/")
        members.append((name, body))
    pos += 60 + size + (size & 1)
paths = []; tot = 0
for i, (name, body) in enumerate(members):
    d = os.path.join(work, str(i)); os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name)
    if body[:4] == b"\x7fELF":
        body, n = uniqsec.process(body); tot += n
    open(p, "wb").write(body); paths.append(p)
print(f"{len(members)} members, {tot} sections renamed")
if os.path.exists(out): os.remove(out)
# ar q with many args: batch
for i in range(0, len(paths), 400):
    subprocess.run(["ar", "qc", out, *paths[i:i + 400]], check=True)
subprocess.run(["ar", "s", out], check=True)
