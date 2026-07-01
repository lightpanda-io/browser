#!/usr/bin/env bash
#
# Agent regression suite. Two layers:
#
#   deterministic  — replay a golden PandaScript against frozen local HTML
#                    fixtures and compare the returned JSON exactly to a
#                    golden file. No API key, no network. Runs on every PR.
#
#   live           — drive the real LLM agent (needs GOOGLE_API_KEY):
#                      * static Q&A: ask closed-form questions about a local
#                        fixture page, substring-match the answer.
#                      * HN save+replay: ask the agent to scrape live Hacker
#                        News and /save a reproducible script, then replay it
#                        token-free and validate the output against a shape
#                        invariant (jq), not exact values.
#
# Usage: test/agent/run.sh [deterministic|live|all|update-golden]  (default: all)
#
# update-golden regenerates golden/hn-front.json from the current fixtures and
# script — review the diff before committing.
#
# Env:
#   LPD            path to the lightpanda binary (default: zig-out/bin/lightpanda)
#   GOOGLE_API_KEY or GEMINI_API_KEY (the binary accepts both) — required for
#                  the live layer; live layer is skipped if neither is set
#   LP_MODEL       Gemini model id for the live layer (default below)
#   LP_HTTP_PROXY  optional proxy for the live HN call only (datacenter IPs are
#                  often blocked by news.ycombinator.com); localhost fixtures
#                  are never proxied
#   MAX_TOKENS     per-live-task total-token ceiling (default: 3000000).
#                  `total` counts cached reads, so a normal HN save is ~1M;
#                  this is a loose backstop against a runaway agent loop.
set -uo pipefail

LAYER="${1:-all}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LPD="${LPD:-$REPO/zig-out/bin/lightpanda}"
# The port is part of the fixture contract: scripts/hn-front.js, the golden
# file, and cases/static-qa.tsv all embed it. Not configurable.
PORT=8081
BASE="http://127.0.0.1:${PORT}"
# Pin an explicit model id — never a *-latest / *-preview alias, which drift.
LP_MODEL="${LP_MODEL:-gemini-3.5-flash}"
MAX_TOKENS="${MAX_TOKENS:-3000000}"

export LIGHTPANDA_DISABLE_TELEMETRY=true

PASS=0
FAIL=0
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
pass()  { green "PASS: $1"; PASS=$((PASS + 1)); }
fail()  { red   "FAIL: $1"; FAIL=$((FAIL + 1)); }
info()  { printf '\033[2m%s\033[0m\n' "$1"; }

[ -x "$LPD" ] || { red "lightpanda binary not found or not executable: $LPD"; exit 2; }

TMP="$(mktemp -d)"
SRV=""
cleanup() {
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

start_server() {
  ( cd "$HERE/fixtures" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  SRV=$!
  for _ in $(seq 1 25); do
    curl -sf "$BASE/hn/front.html" -o /dev/null && return 0
    sleep 0.2
  done
  red "static server failed to start on $BASE"; exit 2
}

# --- deterministic layer -----------------------------------------------------
run_deterministic() {
  info "== deterministic layer (no API key) =="
  if ! "$LPD" agent "$HERE/scripts/hn-front.js" >"$TMP/out" 2>/dev/null; then
    fail "hn-front.js replay (non-zero exit)"; return
  fi
  if ! jq -e . "$TMP/out" >/dev/null 2>&1; then
    fail "hn-front.js replay (output is not valid JSON)"; return
  fi
  local d
  if d="$(diff <(jq -S . "$HERE/golden/hn-front.json") <(jq -S . "$TMP/out"))"; then
    pass "hn-front.js replay matches golden"
  else
    fail "hn-front.js replay differs from golden/hn-front.json"
    info "  diff (golden < , actual > ):"
    printf '%s\n' "$d" | sed 's/^/    /'
  fi
}

# Grep the stable "$usage total=N" line lightpanda prints to stderr and fail
# if a single task blew past the token ceiling (runaway agent loop).
check_usage() {
  local errfile="$1" label="$2" total
  total="$(sed -n '/^\$usage /{s/.*total=\([0-9]\+\).*/\1/p;q}' "$errfile")"
  [ -n "$total" ] && info "  usage: total=${total} tokens ($label)"
  if [ -n "$total" ] && [ "$total" -gt "$MAX_TOKENS" ]; then
    fail "$label exceeded token ceiling ($total > $MAX_TOKENS)"
  fi
}

# --- live layer --------------------------------------------------------------
run_live_qa() {
  info "== live layer: static Q&A (model=$LP_MODEL) =="
  while IFS=$'\t' read -r task expected; do
    [ -z "${task// }" ] && continue
    case "$task" in \#*) continue ;; esac
    timeout 300 "$LPD" agent --provider gemini --model "$LP_MODEL" --task "$task" >"$TMP/out" 2>"$TMP/err"
    if grep -qiF "$expected" "$TMP/out"; then
      pass "Q&A: expected \"$expected\""
    else
      fail "Q&A: expected \"$expected\" not found in answer"
      info "  answer: $(tr '\n' ' ' <"$TMP/out" | cut -c1-200)"
    fi
    check_usage "$TMP/err" "Q&A \"$expected\""
  done <"$HERE/cases/static-qa.tsv"
}

run_live_hn() {
  info "== live layer: HN save + replay (model=$LP_MODEL) =="
  local script="$TMP/hn-live.js" task
  task="$(cat "$HERE/cases/hn-live.task")"

  local proxy_args=()
  [ -n "${LP_HTTP_PROXY:-}" ] && proxy_args=(--http-proxy "$LP_HTTP_PROXY")

  timeout 900 "$LPD" agent --provider gemini --model "$LP_MODEL" "${proxy_args[@]}" --task "$task" --save "$script" >/dev/null 2>"$TMP/err"
  check_usage "$TMP/err" "HN save"

  if [ ! -s "$script" ]; then
    fail "HN save produced no script"; return
  fi
  # A real replay script drives the page — it must navigate and extract.
  if grep -q 'goto(' "$script" && grep -q 'extract(' "$script"; then
    pass "HN saved script looks replayable (has goto + extract)"
  else
    fail "HN saved script missing goto/extract — see below"
    sed 's/^/    /' "$script"
  fi

  # Replay token-free (no --provider/--task => no LLM).
  if ! timeout 300 "$LPD" agent "$script" >"$TMP/out" 2>/dev/null; then
    fail "HN saved script failed on replay"; return
  fi
  if jq -e -f "$HERE/schemas/hn-live.jq" "$TMP/out" >/dev/null 2>&1; then
    pass "HN replay output satisfies shape invariant"
  else
    fail "HN replay output violates schemas/hn-live.jq"
    info "  output: $(tr '\n' ' ' <"$TMP/out" | cut -c1-300)"
  fi
}

# --- dispatch ----------------------------------------------------------------
start_server

case "$LAYER" in
  deterministic) run_deterministic ;;
  live)
    [ -n "${GOOGLE_API_KEY:-}${GEMINI_API_KEY:-}" ] || { red "GOOGLE_API_KEY/GEMINI_API_KEY unset — cannot run live layer"; exit 2; }
    run_live_qa; run_live_hn ;;
  all)
    run_deterministic
    if [ -n "${GOOGLE_API_KEY:-}${GEMINI_API_KEY:-}" ]; then
      run_live_qa; run_live_hn
    else
      info "GOOGLE_API_KEY/GEMINI_API_KEY unset — skipping live layer"
    fi ;;
  update-golden)
    "$LPD" agent "$HERE/scripts/hn-front.js" 2>/dev/null | jq -S . >"$HERE/golden/hn-front.json"
    info "golden/hn-front.json regenerated — review the diff before committing"
    exit 0 ;;
  *) red "unknown layer: $LAYER (use deterministic|live|all|update-golden)"; exit 2 ;;
esac

echo
echo "-------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  green "SUMMARY: $PASS passed, 0 failed"
  exit 0
else
  red "SUMMARY: $PASS passed, $FAIL failed"
  exit 1
fi
