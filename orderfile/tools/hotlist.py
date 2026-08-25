#!/usr/bin/env python3
# usage: hotlist.py <binary> <resident.json> <out-prefix>
# Emits <out>.text and <out>.rodata: symbols overlapping resident pages, in address order,
# plus a per-section summary of resident bytes.
import sys, json, subprocess, bisect, collections, os
binary, resjson, outp = sys.argv[1:4]
syms = []
for line in subprocess.run(["nm", "-S", "--numeric-sort", "--defined-only", binary], capture_output=True, text=True).stdout.splitlines():
    p = line.split()
    if len(p) == 4 and p[2] in "TtWwVvRrDdBb":
        syms.append((int(p[0], 16), int(p[1], 16), p[2], p[3]))
syms.sort()
starts = [s[0] for s in syms]
secs = []
for line in subprocess.run(["readelf", "-SW", binary], capture_output=True, text=True).stdout.splitlines():
    if not line.strip().startswith("[") or "]" not in line: continue
    p = line.split("]", 1)[1].split()
    try:
        secs.append((int(p[2], 16), int(p[4], 16), p[0]))
    except (IndexError, ValueError): pass
secs = [s for s in secs if s[0]]
secs.sort()
sec_starts = [s[0] for s in secs]
def sec_of(va):
    i = bisect.bisect_right(sec_starts, va) - 1
    if i >= 0 and va < secs[i][0] + secs[i][1]: return secs[i][2]
    return "?"
res = json.load(open(resjson))
exe = os.path.realpath(binary)
hot = {"text": collections.OrderedDict(), "rodata": collections.OrderedDict()}
per_sec = collections.Counter()
for m in res:
    if os.path.realpath(m["path"]) != exe: continue
    for pi in m["present"]:
        va = m["lo"] + pi * 4096
        sec = sec_of(va)
        per_sec[sec] += 4
        kind = "text" if sec in (".text", ".text.hot") else ("rodata" if sec in (".rodata", ".rodata.hot") else None)
        if not kind: continue
        i = bisect.bisect_right(starts, va + 4095) - 1
        while i >= 0:
            a, sz, t, n = syms[i]
            end = a + max(sz, 1)
            if end <= va and sz: break
            if a >= va + 4096: i -= 1; continue
            if end > va or (not sz and a >= va):
                hot[kind][n] = a
            i -= 1
            if a < va - 65536: break
for kind in hot:
    names = sorted(hot[kind], key=lambda n: hot[kind][n])
    with open(f"{outp}.{kind}", "w") as f:
        f.write("\n".join(names) + "\n")
    print(f"{kind}: {len(names)} hot symbols")
for sec, kb in per_sec.most_common(12):
    print(f"  {kb:7d} KB {sec}")
