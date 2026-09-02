#!/usr/bin/env bash
# Regenerates orderfile/lightpanda.ld and orderfile/v8.txt from a profile of
# the CDP bench (demo/puppeteer/cdp.js), see orderfile/README.md.
#
# usage: orderfile/tools/regen.sh [zig build args...]
#   The build args are those of the release build minus -Dorderfile, e.g.
#   -Doptimize=ReleaseFast -Dsnapshot_path=../../snapshot.bin -Dcpu=x86_64
#
# Needs root (sudo) for /sys/kernel/debug/fault_around_bytes, a checkout of
# lightpanda-io/demo (DEMO_DIR, npm install done), node, go, python3 and
# binutils. Run from the repository root.
#
# Steps:
#   1. Build with an empty linker script: the unordered binary. Profiling
#      it, rather than one laid out by the current profile, keeps stale
#      entries from surviving forever by sharing a page with a hot neighbour.
#   2. Bench it with 4KB fault-around, dump the resident pages and turn them
#      into the new lightpanda.ld / v8.txt.
#   3. Re-run the build's ld.lld line with the new script to check that it
#      links. The script is a cache input of the whole exe compilation, so
#      building with it would be a second full release compile; the manual
#      relink is the same link in seconds (only V8's hot-marked archive is
#      the one from the current v8.txt, which does not affect parsing).
#      Whether the new profile is any good is measured by the e2e bench.
#
# Environment:
#   DEMO_DIR  demo checkout (default ../demo)
#   RUNS      bench iterations (default 100)
#   OUT       scratch directory (default /tmp/orderfile-regen)
#   RAMDIR    tmpfs the binary is benched from (default /dev/shm)
set -euo pipefail

DEMO_DIR=${DEMO_DIR:-../demo}
RUNS=${RUNS:-100}
OUT=${OUT:-/tmp/orderfile-regen}
RAMDIR=${RAMDIR:-/dev/shm}
FAULT_AROUND=/sys/kernel/debug/fault_around_bytes

ROOT=$(pwd)
DEMO_DIR=$(cd "$DEMO_DIR" && pwd)
TOOLS=$ROOT/orderfile/tools
LD=$ROOT/orderfile/lightpanda.ld
V8_TXT=$ROOT/orderfile/v8.txt

[ -f "$LD" ] || { echo "run from the repository root" >&2; exit 2; }
[ -f "$DEMO_DIR/puppeteer/cdp.js" ] || { echo "DEMO_DIR=$DEMO_DIR is not a demo checkout" >&2; exit 2; }
mkdir -p "$OUT"

# Fault-around is a global knob: whatever happens, put it back.
# debugfs is 0700 root, so every probe under it has to run as root.
if ! mountpoint -q /sys/kernel/debug; then
    sudo mount -t debugfs none /sys/kernel/debug
fi
sudo test -f "$FAULT_AROUND" || { echo "$FAULT_AROUND missing: kernel lacks CONFIG_DEBUG_FS fault-around knob" >&2; exit 2; }
FAULT_AROUND_DEFAULT=$(sudo cat "$FAULT_AROUND")
set_fault_around() { echo "$1" | sudo tee "$FAULT_AROUND" > /dev/null; }

PIDS=()
cleanup() {
    set_fault_around "$FAULT_AROUND_DEFAULT" || true
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2> /dev/null || true
    done
    rm -f "$RAMDIR"/lightpanda-regen-$$-*
}
trap cleanup EXIT

log() { echo "== $*" >&2; }

# The demo web server the bench navigates to (port 1234).
if ! curl -sf -o /dev/null http://127.0.0.1:1234/campfire-commerce/; then
    (cd "$DEMO_DIR" && go run runner/main.go -serve > "$OUT/runner.log" 2>&1) &
    PIDS+=($!)
    for _ in $(seq 50); do
        curl -sf -o /dev/null http://127.0.0.1:1234/campfire-commerce/ && break
        sleep 0.2
    done
fi

# The tmpfs copy the binary is benched from. It outlives the bench: the
# resident pages dump names it, and hotlist.py matches mappings by path.
ram_copy() { echo "$RAMDIR/lightpanda-regen-$$-$(basename "$1")"; }

# profile <binary> <resident.json>
# Runs the CDP bench against <binary> served from tmpfs with 4KB fault-around,
# dumps its resident pages while it is still alive and prints its VmHWM (KB).
profile() {
    local bin=$1 resident=$2
    local ram
    ram=$(ram_copy "$bin")
    cp "$bin" "$ram"
    set_fault_around 4096
    "$ram" serve --insecure-disable-tls-host-verification > /dev/null 2>&1 &
    local pid=$!
    sleep 1
    (cd "$DEMO_DIR" && RUNS=$RUNS node puppeteer/cdp.js > "$OUT/bench.out")
    sleep 2
    python3 "$TOOLS/pagemap.py" "$pid" "$resident" >&2
    local hwm
    hwm=$(grep VmHWM "/proc/$pid/status" | grep -oP '\d+')
    kill "$pid"
    while kill -0 "$pid" 2> /dev/null; do sleep 0.2; done
    set_fault_around "$FAULT_AROUND_DEFAULT"
    echo "$hwm"
}

# 1. Unordered build. The script's content is a cache input, so the timestamp
#    guarantees a fresh link and thus a --verbose-link line listing every
#    object and archive of the link.
log "building without ordering"
printf '/* unordered profile build, %s */\n' "$(date +%s%N)" > "$OUT/empty.ld"
zig build "$@" -Dorderfile="$OUT/empty.ld" --verbose-link 2> "$OUT/link.log" \
    || { cat "$OUT/link.log" >&2; exit 1; }
cp zig-out/bin/lightpanda "$OUT/unordered"
# The verbose-link line is "ld.lld <args>", indented, and prefixed with
# "error: " on some paths; only the args replay under `zig ld.lld`.
grep -m1 -F 'lightpanda_zcu.o' "$OUT/link.log" | sed -E 's/^[[:space:]]*(error: )?ld\.lld //' > "$OUT/link.line"
[ -s "$OUT/link.line" ] || { echo "no ld.lld line in $OUT/link.log" >&2; exit 1; }
case $(head -c 1 "$OUT/link.line") in
    -) ;;
    *) echo "link line is not an ld.lld invocation: $(cut -c 1-100 "$OUT/link.line")" >&2; exit 1 ;;
esac

# Link inputs -> objects/archives for gen_order.py; the V8 archive is
# handled separately (its symbols go to v8.txt).
V8_ARCHIVE=
OBJS=()
for arg in $(cat "$OUT/link.line"); do
    case $arg in
        *.o | *.a) [ -f "$arg" ] || continue ;;
        *) continue ;;
    esac
    case $(basename "$arg") in
        libc_v8*.a) V8_ARCHIVE=$arg ;;
        *) case " ${OBJS[*]:-} " in *" $arg "*) ;; *) OBJS+=("$arg") ;; esac ;;
    esac
done
[ -n "$V8_ARCHIVE" ] || { echo "no V8 archive in the link line" >&2; exit 1; }
log "${#OBJS[@]} link inputs, V8 archive $V8_ARCHIVE"

# 2. Profile the unordered binary at 4KB fault-around.
log "profiling the unordered binary (RUNS=$RUNS)"
HOT_SET_KB=$(profile "$OUT/unordered" "$OUT/resident.json")
python3 "$TOOLS/hotlist.py" "$(ram_copy "$OUT/unordered")" "$OUT/resident.json" "$OUT/hot" >&2
[ -s "$OUT/hot.text" ] || { echo "empty profile, see $OUT/resident.json" >&2; exit 1; }
python3 "$TOOLS/gen_order.py" "$OUT/hot.text" "$OUT/hot.rodata" "$OUT/lightpanda.ld" \
    --v8 "$V8_ARCHIVE" "$OUT/v8.txt" "${OBJS[@]}" > "$OUT/gen_order.stats"
cat "$OUT/gen_order.stats" >&2
[ -s "$OUT/v8.txt" ] || { echo "no V8 symbols in the profile" >&2; exit 1; }

# 3. Does it link? Same objects, same flags, new script.
log "linking with the new orderfile"
# shellcheck disable=SC2046
zig ld.lld $(sed "s#-T [^ ]*#-T $OUT/lightpanda.ld#; s#-o [^ ]*#-o $OUT/linked#" "$OUT/link.line")
"$OUT/linked" version > /dev/null

cp "$OUT/lightpanda.ld" "$LD"
cp "$OUT/v8.txt" "$V8_TXT"
printf 'hot set %sKB resident at 4KB fault-around: %s text, %s rodata symbols\n' \
    "$HOT_SET_KB" "$(wc -l < "$OUT/hot.text")" "$(wc -l < "$OUT/hot.rodata")" | tee "$OUT/result.txt"
