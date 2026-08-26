#!/usr/bin/env python3
"""Give -fno-unique-section-names objects unique section names again.

Every SHT_PROGBITS section named exactly `.text`, `.text.unlikely.`,
`.text.startup.`, `.text.exit.` or `.rodata` gets the name of the symbol it
defines appended (`.text` -> `.text.<sym>`), so a linker script can address
individual functions. The new names are appended to .shstrtab, which is
moved to the end of the file. usage: uniqsec.py in.o out.o
"""
import struct, sys
SHT_PROGBITS, SHT_SYMTAB = 1, 2
SHF_EXECINSTR = 0x4
RENAME = (".text", ".text.unlikely.", ".text.startup.", ".text.exit.", ".rodata")
def process(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("not ELF64 LE")
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    assert e_shentsize == 64
    shdrs = []
    for i in range(e_shnum):
        shdrs.append(list(struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * 64)))
    shstr = shdrs[e_shstrndx]
    shstrtab = bytearray(data[shstr[4]:shstr[4] + shstr[5]])
    def name(off):
        end = shstrtab.index(b"\0", off)
        return shstrtab[off:end].decode()
    # symbols: section index -> best symbol name
    best = {}
    for sh in shdrs:
        if sh[1] != SHT_SYMTAB: continue
        strtab = shdrs[sh[6]]
        strdata = data[strtab[4]:strtab[4] + strtab[5]]
        n = sh[5] // 24
        for i in range(n):
            st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, sh[4] + i * 24)
            if st_shndx == 0 or st_shndx >= 0xff00 or st_name == 0: continue
            typ, bind = st_info & 0xf, st_info >> 4
            if typ not in (1, 2): continue  # OBJECT, FUNC
            end = strdata.index(b"\0", st_name)
            nm = strdata[st_name:end].decode(errors="replace")
            if nm.startswith(".L"): continue
            score = (st_value == 0, bind != 0, st_size)
            cur = best.get(st_shndx)
            if cur is None or score > cur[0]:
                best[st_shndx] = (score, nm)
    renamed = 0
    for idx, sh in enumerate(shdrs):
        if sh[1] != SHT_PROGBITS: continue
        nm = name(sh[0])
        if nm not in RENAME or idx not in best: continue
        sep = "" if nm.endswith(".") else "."
        new = (nm + sep + best[idx][1]).encode() + b"\0"
        sh[0] = len(shstrtab)
        shstrtab += new
        renamed += 1
    out = bytearray(data)
    # move shstrtab to EOF (8-aligned)
    pad = (-len(out)) % 8
    out += b"\0" * pad
    shstr[4] = len(out); shstr[5] = len(shstrtab)
    out += shstrtab
    for i, sh in enumerate(shdrs):
        struct.pack_into("<IIQQQQIIQQ", out, e_shoff + i * 64, *sh)
    return bytes(out), renamed
if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    out, n = process(data)
    open(sys.argv[2], "wb").write(out)
    print(f"{sys.argv[1]}: renamed {n} sections")
