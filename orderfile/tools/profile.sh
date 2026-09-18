#!/usr/bin/env bash
# Profiles a lightpanda binary on the CDP bench (demo/puppeteer/cdp.js): the
# pages of its text and rodata resident at 4KB fault-around, as hot symbol
# lists. Run by `zig build orderfile`, see orderfile/README.md.
#
# usage: profile.sh <lightpanda> <out-dir>
#   Writes hot.text and hot.rodata (symbols in address order), resident.json,
#   bench.out and result.txt into <out-dir>.
#
# Needs root (sudo) for /sys/kernel/debug/fault_around_bytes, a checkout of
# lightpanda-io/demo (DEMO_DIR, npm install done), node, go, python3 and
# binutils.
#
# Environment:
#   DEMO_DIR  demo checkout (default ../demo, next to the repository)
#   RUNS      bench iterations (default 100)
#   RAMDIR    tmpfs the binary is benched from (default /dev/shm)
set -euo pipefail

BIN=$1
OUT=$2
TOOLS=$(cd "$(dirname "$0")" && pwd)
DEMO_DIR=${DEMO_DIR:-$TOOLS/../../../demo}
RUNS=${RUNS:-100}
RAMDIR=${RAMDIR:-/dev/shm}
FAULT_AROUND=/sys/kernel/debug/fault_around_bytes

DEMO_DIR=$(cd "$DEMO_DIR" && pwd)
[ -f "$DEMO_DIR/puppeteer/cdp.js" ] || { echo "DEMO_DIR=$DEMO_DIR is not a demo checkout" >&2; exit 2; }
mkdir -p "$OUT"

# Fault-around is a global knob: whatever happens, put it back.
# debugfs is 0700 root, so every probe under it has to run as root.
sudo true || { echo "root (sudo) is needed to set $FAULT_AROUND" >&2; exit 2; }
if ! mountpoint -q /sys/kernel/debug; then
    sudo mount -t debugfs none /sys/kernel/debug
fi
sudo test -f "$FAULT_AROUND" || { echo "$FAULT_AROUND missing: kernel lacks CONFIG_DEBUG_FS fault-around knob" >&2; exit 2; }
FAULT_AROUND_DEFAULT=$(sudo cat "$FAULT_AROUND")
set_fault_around() { echo "$1" | sudo tee "$FAULT_AROUND" > /dev/null; }

# The tmpfs copy the binary is benched from: on ext4 with a recent kernel,
# large page-cache folios are mapped whole and hide the 64KB-window behaviour.
# It outlives the bench: the resident pages dump names it, and hotlist.py
# matches mappings by path.
RAM=$RAMDIR/lightpanda-profile-$$

PIDS=()
cleanup() {
    set_fault_around "$FAULT_AROUND_DEFAULT" || true
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2> /dev/null || true
    done
    rm -f "$RAM"
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

log "profiling $BIN (RUNS=$RUNS)"
cp "$BIN" "$RAM"
set_fault_around 4096
"$RAM" serve --insecure-disable-tls-host-verification > /dev/null 2>&1 &
PID=$!
sleep 1
(cd "$DEMO_DIR" && RUNS=$RUNS node puppeteer/cdp.js > "$OUT/bench.out")
sleep 2
python3 "$TOOLS/pagemap.py" "$PID" "$OUT/resident.json" >&2
HOT_SET_KB=$(grep VmHWM "/proc/$PID/status" | grep -oP '\d+')
kill "$PID"
while kill -0 "$PID" 2> /dev/null; do sleep 0.2; done
set_fault_around "$FAULT_AROUND_DEFAULT"

python3 "$TOOLS/hotlist.py" "$RAM" "$OUT/resident.json" "$OUT/hot" >&2
[ -s "$OUT/hot.text" ] || { echo "empty profile, see $OUT/resident.json" >&2; exit 1; }
printf 'hot set %sKB resident at 4KB fault-around: %s text, %s rodata symbols\n' \
    "$HOT_SET_KB" "$(wc -l < "$OUT/hot.text")" "$(wc -l < "$OUT/hot.rodata")" | tee "$OUT/result.txt" >&2
