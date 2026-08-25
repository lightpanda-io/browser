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
  changes, so the profile decays a little with every commit; regenerate it
  when CI's VmHWM creeps.
- Link-time cost: LLD name-checks every input section against every pattern
  of every input-section description, so the script scopes patterns to their
  object file (`*api.o(...)`). The shipped script covers Zig/Rust/C only
  (~4k patterns, ~2s of link). Once V8's functions are addressable (below) the
  script grows to ~26k patterns and the release link to ~26s; one pattern per
  line instead of per file would make that 85s. Debug builds pay nothing.
- The prebuilt V8 archive is compiled with `-fno-unique-section-names`
  (Chromium hardcodes it), so all of V8's function sections are named `.text`
  and the script cannot address them. `tools/uniqar.py` rewrites the archive so
  each section is named `.text.<symbol>` (`.rodata.<symbol>`); link against
  that copy via `-Dprebuilt_v8_path=...`. Without it the script still orders
  the Zig, Rust and C code, with a smaller gain.

## Regenerating the profile

The profile is a list of resident pages captured at 4KB granularity, so
fault-around has to be disabled while profiling (root):

```bash
# 1. Build with the current script (or none) and copy the binary to tmpfs.
#    Bench from tmpfs: on ext4 with a recent kernel, large page-cache folios
#    are mapped whole and hide the 64KB-window behaviour that CI sees.
zig build -Doptimize=ReleaseFast -Dsnapshot_path=../../snapshot.bin -Dcpu=x86_64 \
    -Dorderfile=orderfile/lightpanda.ld
cp zig-out/bin/lightpanda /tmp/lightpanda

# 2. Run the workload with fault-around off and dump which pages are resident.
sudo sh -c 'echo 4096 > /sys/kernel/debug/fault_around_bytes'
/tmp/lightpanda serve --insecure-disable-tls-host-verification & LP=$!
(cd ../demo && RUNS=100 node puppeteer/cdp.js)
sleep 5
python3 orderfile/tools/pagemap.py $LP resident.json
kill $LP
sudo sh -c 'echo 65536 > /sys/kernel/debug/fault_around_bytes'

# 3. Resident pages -> hot symbol lists (address order), then -> linker script.
#    gen_order.py needs every object/archive of the link to map symbols to
#    section names: `zig build ... --verbose-link` prints the ld.lld line.
python3 orderfile/tools/hotlist.py /tmp/lightpanda resident.json hot
python3 orderfile/tools/gen_order.py hot.text hot.rodata orderfile/lightpanda.ld \
    <uniq-v8.a> .zig-cache/o/*/lightpanda_zcu.o .zig-cache/o/*/*.a ...
```

Profiles from several runs can be concatenated before `gen_order.py`
(duplicates are dropped, first occurrence wins); the shipped script is the
union of a profile of the unordered binary and one of the ordered binary.

To check the result without root, compare `VmHWM` from `/proc/<pid>/status`
after the bench, and look at what is still resident outside the hot sections
with `pagemap.py` + `nm`.
