#!/usr/bin/env bash
# Build a macOS SDK shim that lets Zig 0.15.x link arm64-macos binaries
# on macOS 26+.
#
# Problem:
#   macOS 26 CommandLineTools dropped arm64-macos from the system .tbd
#   library stubs — every export now lists arm64e-macos only. Zig 0.15.x
#   bundles libc/darwin/libSystem.tbd that still has arm64-macos but is
#   pinned to macOS 15.5 in its SDKSettings. Zig's auto-detection picks
#   the higher-numbered system SDK, falls back to the system libSystem,
#   and the arm64 link fails with "undefined symbol: _abort" (and
#   ~30 other libSystem / CoreFoundation / SystemConfiguration symbols).
#
# Output:
#   $1/sdk/  — hybrid SDK:
#     - usr/include, usr/share, Library, System/iOSSupport are symlinks
#       to the live system SDK (read-only, safe to share)
#     - usr/lib/libSystem.tbd is copied from Zig's bundled libc/darwin
#       (the one with arm64-macos exports)
#     - every other .tbd under usr/lib, System/Library/Frameworks, and
#       System/Library/PrivateFrameworks is a copy with arm64-macos
#       appended to every targets list that previously listed only
#       arm64e-macos. Each export block applies to the same targets it
#       already did, plus arm64-macos — the linker resolves arm64-macos
#       symbols using the same definitions Apple ships for arm64e-macos.
#   $1/bin/xcrun — wrapper that returns the shim path for
#     `--show-sdk-path` / `--show-sdk-version` on `--sdk macosx`, and
#     passes everything else through to /usr/bin/xcrun. The wrapper
#     reads the shim path from LIGHTPANDA_DARWIN_SDK_SHIM at runtime,
#     so moving the output directory keeps working as long as the env
#     var is updated.
#
# Re-run after:
#   - Xcode CommandLineTools updates (the symlinked .tbd files change)
#   - Zig version bumps (the bundled libSystem.tbd / SDKSettings move)
#
# The shim is host-specific (every symlink is absolute) and is not
# meant to be checked into the repo. The Makefile runs this script
# automatically when the system SDK lacks arm64-macos exports.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <output-dir>" >&2
    exit 64
fi

OUTPUT="$1"
SYS_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [ -z "$SYS_SDK" ] || [ ! -d "$SYS_SDK" ]; then
    echo "error: /usr/bin/xcrun --sdk macosx --show-sdk-path did not return a usable path" >&2
    echo "Hint: install Xcode CommandLineTools (xcode-select --install)." >&2
    exit 1
fi

# Discover Zig's lib_dir from `zig env`. The output is Zig-literal format
# (`.field = "value"`), parsed here with a defensive grep+awk pair so we
# don't depend on jq.
ZIG_LIB="$(zig env 2>/dev/null | awk -F'"' '/[[:space:]]\.lib_dir = "/ {print $2; exit}')"
if [ -z "$ZIG_LIB" ] || [ ! -d "$ZIG_LIB" ]; then
    echo "error: cannot determine Zig's lib_dir (got '$ZIG_LIB' from \`zig env\`)" >&2
    echo "Hint: ensure \`zig\` is on PATH and reports a valid lib_dir." >&2
    exit 1
fi
ZIG_LIBC="$ZIG_LIB/libc/darwin"

if [ ! -f "$ZIG_LIBC/libSystem.tbd" ]; then
    echo "error: Zig's bundled libSystem.tbd not found at $ZIG_LIBC/libSystem.tbd" >&2
    echo "Hint: this script targets Zig 0.15.x. Newer Zig may not need the shim." >&2
    exit 1
fi

SHIM_SDK="$OUTPUT/sdk"
SHIM_BIN="$OUTPUT/bin"

# Wipe previous artifacts without `rm -rf` (some sandboxes block it).
find "$SHIM_SDK" -mindepth 1 -delete 2>/dev/null || true
find "$SHIM_BIN" -mindepth 1 -delete 2>/dev/null || true
mkdir -p "$SHIM_SDK/usr/lib" "$SHIM_BIN"

# Read-only mirrors that don't need patching.
for p in usr/include usr/share Library System/iOSSupport; do
    if [ -e "$SYS_SDK/$p" ]; then
        mkdir -p "$SHIM_SDK/$(dirname "$p")"
        ln -sfn "$SYS_SDK/$p" "$SHIM_SDK/$p"
    fi
done
cp "$SYS_SDK/SDKSettings.json" "$SHIM_SDK/SDKSettings.json"
cp "$ZIG_LIBC/libSystem.tbd" "$SHIM_SDK/usr/lib/libSystem.tbd"

# Patch a single .tbd by adding arm64-macos next to every arm64e-macos
# token. The .tbd format groups symbols by target list, so duplicating
# arm64e-macos as "arm64e-macos, arm64-macos" extends every export to
# the arm64 variant. Skip files that already list arm64-macos.
patch_tbd() {
    local src="$1" dst="$2"
    if grep -q "arm64e-macos" "$src" 2>/dev/null && ! grep -q "arm64-macos" "$src" 2>/dev/null; then
        sed 's/arm64e-macos/arm64e-macos, arm64-macos/g' "$src" > "$dst"
    else
        cp "$src" "$dst"
    fi
}

# usr/lib top-level libraries (libcurl.tbd, libsqlite3.tbd, libxml2.tbd, ...).
(cd "$SYS_SDK/usr/lib" && find . -maxdepth 2 -name "*.tbd") | while read -r f; do
    case "$f" in ./libSystem.tbd) continue;; esac
    real="$(readlink -f "$SYS_SDK/usr/lib/$f")"
    [ -f "$real" ] || continue
    out="$SHIM_SDK/usr/lib/$f"
    mkdir -p "$(dirname "$out")"
    patch_tbd "$real" "$out"
done

# Per-framework hybrid: symlink Headers / Modules / Resources, patch each .tbd.
build_frameworks() {
    local src_root="$1" dst_root="$2"
    [ -d "$src_root" ] || return 0
    mkdir -p "$dst_root"
    for fw in "$src_root"/*.framework; do
        [ -d "$fw" ] || continue
        local fw_name out
        fw_name="$(basename "$fw")"
        out="$dst_root/$fw_name"
        mkdir -p "$out"
        for sub_path in "$fw"/*; do
            [ -e "$sub_path" ] || continue
            local sub
            sub="$(basename "$sub_path")"
            [ "$sub" = "Versions" ] && continue
            case "$sub" in
                *.tbd) ;;
                *) ln -sfn "$fw/$sub" "$out/$sub";;
            esac
        done
        for tbd in "$fw"/*.tbd; do
            [ -e "$tbd" ] || continue
            real="$(readlink -f "$tbd")"
            patch_tbd "$real" "$out/$(basename "$tbd")"
        done
        if [ -d "$fw/Versions" ]; then
            mkdir -p "$out/Versions"
            for v in "$fw/Versions"/*; do
                [ -e "$v" ] || [ -L "$v" ] || continue
                local vname
                vname="$(basename "$v")"
                if [ -L "$v" ]; then
                    ln -sfn "$(readlink "$v")" "$out/Versions/$vname"
                    continue
                fi
                mkdir -p "$out/Versions/$vname"
                for sub_path in "$v"/*; do
                    [ -e "$sub_path" ] || continue
                    local sub
                    sub="$(basename "$sub_path")"
                    case "$sub" in
                        *.tbd) ;;
                        *) ln -sfn "$v/$sub" "$out/Versions/$vname/$sub";;
                    esac
                done
                for tbd in "$v"/*.tbd; do
                    [ -e "$tbd" ] || continue
                    real="$(readlink -f "$tbd")"
                    patch_tbd "$real" "$out/Versions/$vname/$(basename "$tbd")"
                done
            done
        fi
    done
}

build_frameworks "$SYS_SDK/System/Library/Frameworks" "$SHIM_SDK/System/Library/Frameworks"
build_frameworks "$SYS_SDK/System/Library/PrivateFrameworks" "$SHIM_SDK/System/Library/PrivateFrameworks"

# xcrun wrapper. Reads LIGHTPANDA_DARWIN_SDK_SHIM at runtime so the Makefile
# can move the output dir without rebuilding the wrapper. Passes everything
# except `--show-sdk-path` / `--show-sdk-version` for `--sdk macosx` through
# to /usr/bin/xcrun unchanged.
cat > "$SHIM_BIN/xcrun" <<'WRAPPER'
#!/bin/sh
# Auto-generated by scripts/darwin-sdk-shim.sh. Do not edit; re-run
# the generator script if behavior needs to change.
SHIM_SDK="${LIGHTPANDA_DARWIN_SDK_SHIM:-}"
if [ -z "$SHIM_SDK" ] || [ ! -d "$SHIM_SDK" ] || [ "$(uname)" != "Darwin" ]; then
    exec /usr/bin/xcrun "$@"
fi

sdk="macosx"
sdk_next=0
want_path=0
want_version=0
for a in "$@"; do
    if [ "$sdk_next" = "1" ]; then
        sdk="$a"
        sdk_next=0
        continue
    fi
    case "$a" in
        --sdk=*) sdk="${a#--sdk=}";;
        --sdk) sdk_next=1;;
        --show-sdk-path|-show-sdk-path) want_path=1;;
        --show-sdk-version|-show-sdk-version) want_version=1;;
    esac
done

if [ "$sdk" = "macosx" ]; then
    if [ "$want_path" = "1" ]; then
        printf '%s\n' "$SHIM_SDK"
        exit 0
    fi
    if [ "$want_version" = "1" ]; then
        version=$(sed -n 's/.*"MinimalDisplayName":"\([^"]*\)".*/\1/p' "$SHIM_SDK/SDKSettings.json" 2>/dev/null)
        printf '%s\n' "${version:-15.5}"
        exit 0
    fi
fi

exec /usr/bin/xcrun "$@"
WRAPPER
chmod +x "$SHIM_BIN/xcrun"

count_patched="$(find "$SHIM_SDK/usr/lib" "$SHIM_SDK/System" -name "*.tbd" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "darwin-sdk-shim: $count_patched .tbd files patched at $SHIM_SDK"
