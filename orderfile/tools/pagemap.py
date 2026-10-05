#!/usr/bin/env python3
# Dump resident (present) pages per file-backed mapping of a live process.
import sys, json, struct, os
pid = int(sys.argv[1]); out = sys.argv[2]
maps = []
for line in open(f"/proc/{pid}/maps"):
    p = line.split()
    if len(p) < 6: continue
    lo, hi = (int(x, 16) for x in p[0].split('-'))
    maps.append(dict(lo=lo, hi=hi, perms=p[1], off=int(p[2], 16), path=p[5]))
res = []
with open(f"/proc/{pid}/pagemap", "rb") as pm:
    for m in maps:
        n = (m["hi"] - m["lo"]) // 4096
        pm.seek(m["lo"] // 4096 * 8)
        if m["lo"] >= 1 << 47: continue
        data = pm.read(n * 8)
        present = [i for i in range(n) if struct.unpack_from("<Q", data, i * 8)[0] >> 63 & 1]
        m["present"] = present
        m["n"] = n
        res.append(m)
json.dump(res, open(out, "w"))
tot = 0
for m in res:
    if m["present"]:
        tot += len(m["present"])
print(f"resident pages total {tot} = {tot*4} KB")
