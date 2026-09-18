# Hot-code orderfile

`lightpanda.ld` is an LLD linker script that gathers the functions and
read-only data touched by a typical session into two contiguous output
sections, `.text.hot` and `.rodata.hot`, placed in front of the cold `.text`
and `.rodata`. It only affects layout; no code changes.

## Why

The kernel maps file-backed pages in 64KB fault-around windows
(`/sys/kernel/debug/fault_around_bytes`). With the default link order the hot
code is scattered across the whole 40MB of text, so every window that holds a
single executed byte becomes resident: ~17MB of `.text` and ~4MB of `.rodata`
for a hot set that is really 7.5MB + 2MB. Packing the hot set contiguously
takes the CDP bench (`demo/puppeteer/cdp.js`, 100 runs) from VmHWM ~28.2MB to
~25.3MB with the stock V8 archive and ~21.2MB once V8 is addressable too (see
below), with no change in run duration.

## How it is applied

- Opt-in via `-Dorderfile=orderfile/lightpanda.ld`; CI passes it for the Linux
  release artifact and the e2e bench build. Local release builds don't, so
  they keep the sub-second link. Linux/LLD only (it is an ELF linker script).
- The exe and every C library it links are built with
  `-ffunction-sections -fdata-sections` so each function/datum has its own
  input section for the script to address.
- Patterns that match nothing are ignored by LLD, so a stale script degrades
  gracefully: renamed or removed functions simply fall back into cold `.text`.
  Zig's `__anon_NNN` names (~7% of the patterns) renumber on unrelated
  changes, so the profile decays a little with every commit; it is
  regenerated nightly by CI (below).
- Link-time cost: LLD name-checks every input section against every pattern
  of every input-section description, so the script scopes patterns to their
  object file (`*api.o(...)`). The shipped script covers Zig/Rust/C only
  (~4k patterns, ~2s of link). Once V8's functions are addressable (below) the
  script grows to ~26k patterns and the release link to ~26s; one description
  per pattern instead of per file would make that 85s (the line breaks inside
  a description are free, they exist for the diff). Debug builds pay nothing.
- The prebuilt V8 archive is compiled with `-fno-unique-section-names`
  (Chromium hardcodes it), so all of V8's function sections are named `.text`
  and the script cannot address them. `mark_hot_sections.zig` (run
  automatically by `build.zig` when an orderfile is set) rewrites the archive,
  renaming just the *hot* sections to `.text.hot.<symbol>` /
  `.rodata.hot.<symbol>` so the script gathers all of V8 with one
  `.text.hot.*` glob (which keeps the link at ~2s instead of ~26s). The
  browser's own hot Zig/Rust/C sections are matched by explicit per-file
  patterns. The rewritten archive is a build cache artifact (~132MB -> ~158MB;
  LLVM objects share .shstrtab with .strtab, so each touched member grows);
  the linked binary is byte-for-byte unaffected.
- V8's embedded builtins blob (the `Builtins_*` symbols, one ~2MB `.text`
  section) is deliberately left cold. Pulling it into `.text.hot` shifts the
  layout so that V8's runtime code range (a separate mmap) no longer reaches
  the blob with a pc-relative call, and V8 then copies the whole 2MB blob into
  an executable anonymous mapping at startup (+~1.8MB RSS, deterministic).
  `mark_hot_sections.zig` and `gen_order.py` both skip `Builtins_*`.

## Regenerating the profile

```bash
# root for /sys/kernel/debug/fault_around_bytes; ../demo checked out with
# `npm install` done; node, go, python3 and binutils on the PATH.
make orderfile
# or, with the release build's args (-Dorderfile included: it selects the
# sectioned object build the profile is taken from):
zig build orderfile -Doptimize=ReleaseFast -Dsnapshot_path=../../snapshot.bin -Dorderfile=orderfile/lightpanda.ld -Dcpu=x86_64
```

The `orderfile` step

1. builds the release exe without a script: the unordered binary;
2. runs the CDP bench (`demo/puppeteer/cdp.js`, 100 runs; `tools/profile.sh`,
   env `DEMO_DIR`, `RUNS`, `RAMDIR`) against it with fault-around set to 4KB,
   dumps the pages that are resident (`pagemap.py`) and turns them into hot
   symbol lists in address order (`hotlist.py`);
3. turns those into the new `lightpanda.ld` / `v8.txt` (`gen_order.py`),
   mapping symbols to their object file with `objdump` over the link inputs:
   the Zig object (`lightpanda_zcu.o`, which Zig leaves next to the exe in
   its cache directory), the C libraries, the Rust staticlib and the V8
   archive from the build graph, plus the libc++/libunwind/compiler_rt
   archives Zig links from its global cache (every copy there has the same
   member names, which is all the script needs);
4. builds with the new script and runs `lightpanda version`. The script is
   an input of the whole exe compilation, so this is a second compile of the
   Zig code; the dependencies are cached;
5. writes the two files into `orderfile/` and the profile (`hot.text`,
   `resident.json`, `result.txt`, `gen_order.stats`, ...) into
   `zig-out/orderfile/`.

Whether the new profile is any good is not measured here; the e2e bench's
`MAX_VmHWM` gate is, on the next push to `main`.

The profile is a list of resident pages, so every function sharing a 4KB page
with a hot one is counted as hot. Profiling the *unordered* binary keeps that
over-inclusion random: a profile of the ordered binary would re-include every
function that went cold but still sits in `.text.hot` next to a hot one, and
the hot set would only ever grow. Over-inclusion is the cheap side of the
trade anyway (a hot function left out costs a whole 64KB cold window; one
included needlessly costs its own size), and `.text.hot` is packed in
address order of the profile, so functions that run together stay together.

The binary is benched from tmpfs (`RAMDIR`, default `/dev/shm`): on ext4 with
a recent kernel, large page-cache folios are mapped whole and hide the
64KB-window behaviour that CI sees. The `x86_64` profile is applied to the
`aarch64` release too; it carries over as far as the section and symbol
names coincide, nothing is measured on `aarch64`.

To look at what is still resident outside the hot sections, run the bench by
hand and use `pagemap.py` + `nm` on the live process.
