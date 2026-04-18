#!/usr/bin/env bash
set -euo pipefail

cd -- "$(cd -- "$(dirname -- "$0")" && pwd)"

tmp_in="$(mktemp)"
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_in" "$tmp_out"' EXIT

echo "generating build.zig.zon.nix from build.zig.zon..."

zon2nix > "$tmp_in"

echo "patching non-canonical urls in build.zig.zon.nix"

# IMPORTANT: the program below assumes that build.zig.zon is correct and 
# that ".url = ..." is placed above ".hash = ...", which is Zig's default
# behaviour.

awk '
  # build mapping from dependency hash/name -> canonical url 
  # for build.zig.zon ONLY
  FNR == NR {
    # match for `.url = "..."`
    # remember "..." zon_url (without quotation)
    if (match($0, /^[[:space:]]*\.url[[:space:]]*=[[:space:]]*"([^"]+)"/, m)) {
      zon_url = m[1]
    }
    # match for `.hash = "..."` for current `zon_url`
    # map canonical url => hash value (without quotation)
    if (match($0, /^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*"([^"]+)"/, m) && zon_url != "") {
      canon[m[1]] = zon_url
      zon_url = ""
    }
    next
  }

  function insert_after(line_no, text,    i) {
    for (i = n; i > line_no; i--) {
      item[i + 1] = item[i]
    }
    item[line_no + 1] = text
    n++
  }

  function flush(    i, indent, m) {
    # only rewrite if:
    # - a `name = "..."` is found for this item,
    # - a `url = "..."` is found with line number to patch,
    # - and the canonical URL is not a git+ url, as zon2nix turns those into 
    #   fetchgit-style entries
    if (name in canon && url_line && canon[name] !~ /^git\+/) {
      sub(/"[^"]+"/, "\"" canon[name] "\"", item[url_line])
    }
    # chromium +archive tarballs are flat archives, so fetchzip must preserve
    # their root layout with `striproot = false;`.
    # if we are in a fetchzip item, the final url contains /+archive/, and the
    # generated item does not already contain striproot, insert that line.
    if (is_fetchzip && url_line && item[url_line] ~ /\/\+archive\// && !has_strip_root) {
      indent = "  "
      if (match(item[url_line], /^([[:space:]]*)url[[:space:]]*=.*$/, m)) {
        indent = m[1]
      }
      insert_after(url_line, indent "stripRoot = false;")
    }
    for (i = 1; i <= n; i++) {
      print item[i]
      delete item[i]
    }
    n = 0
    name = ""
    url_line = 0
    is_fetchzip = 0
    has_strip_root = 0
    in_item = 0
  }

  # not inside a linkfarm item
  !in_item {
    # line just opening `{` => linkfarm item starts here => in item
    if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
      in_item = 1
      n = 1
      item[n] = $0
    } else {
      # regular line
      print
    }
    next
  }

  # inside a linkfarm item
  {
    item[++n] = $0

    # found `path = fetchzip {` inside this linkFarm item
    if ($0 ~ /^[[:space:]]*path[[:space:]]*=[[:space:]]*fetchzip[[:space:]]*\{[[:space:]]*$/) {
      is_fetchzip = 1
    }
    # found linkfarm item `name = "..."`
    if (match($0, /^[[:space:]]*name[[:space:]]*=[[:space:]]*"([^"]+)";/, m)) {
      name = m[1]
    }
    # found link farm item `url = "..."`
    if (match($0, /^[[:space:]]*url[[:space:]]*=[[:space:]]*"([^"]+)";/, m)) {
      url_line = n
    }
    # remember whether stripRoot is already present so we do not insert it twice
    if ($0 ~ /^[[:space:]]*stripRoot[[:space:]]*=[[:space:]]*false;[[:space:]]*$/) {
      has_strip_root = 1
    }
    # match for "}" => found end of linkfarm item
    if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) {
      flush()
    }
  }

  END {
    if (in_item) {
      flush()
    }
  }
' build.zig.zon "$tmp_in" > "$tmp_out"

mv "$tmp_out" build.zig.zon.nix

if rg -q 'release-assets\.githubusercontent\.com' build.zig.zon.nix; then
  echo 'error: build.zig.zon.nix still contains redirected GitHub asset URLs' >&2
  exit 1
fi

echo 'updated build.zig.zon.nix'
