#!/usr/bin/env python3
"""Post-sync compatibility patch for the V8 source tree on Windows.

gclient sync checks out a tree that targets the SDK version the newest
Visual Studio release prefers (10.0.28000.0), while the build machines
only carry SDK 10.0.26100.0. The V8 build also has to match the toolchain
model used here: the dynamic CRT (msvcrt.dll) that the Zig mingw linker
links against, and no Control Flow Guard flags (the __guard_* symbols
would clash with the mingw CRT).

This script rewrites the affected build files with plain string
replacements (no git apply, so it survives context drift) so the freshly
synced tree builds with the locally installed toolchain.

Usage: python windows-v8-compat.py <v8_tree_root>

Every replacement reports one of:
  APPLIED  - the tree was changed now
  ALREADY  - the tree is already in the patched state
  SKIPPED  - the target was not found (a warning, not an error)
so the script is idempotent and can be re-run on any tree state.
"""

import os
import sys


def patch_file(path, edits):
    """Apply edits to the file at `path`.

    `edits` is a list of (kind, search, replace) tuples. kind is
    "replace" (swap every occurrence of search with replace) or
    "comment" (comment out lines whose content starts with search).
    Prints one status line per edit. Never raises on missing targets.
    """
    if not os.path.isfile(path):
        print("SKIPPED: %s: file not found" % path)
        return

    # newline="" keeps the original line endings untouched.
    with open(path, "r", encoding="utf-8", newline="") as f:
        content = f.read()

    changed = False
    for kind, search, replace in edits:
        if kind == "replace":
            if search not in content:
                if replace in content:
                    print("ALREADY: %s: %s" % (path, search))
                else:
                    print("SKIPPED: %s: %s not found" % (path, search))
                continue
            content = content.replace(search, replace)
            print("APPLIED: %s: %s -> %s" % (path, search, replace))
            changed = True
        elif kind == "comment":
            lines = content.splitlines(keepends=True)
            active = 0
            commented = 0
            for i, line in enumerate(lines):
                stripped = line.strip()
                if stripped.startswith(search):
                    # Keep the indentation, comment the statement out.
                    lines[i] = line.replace(search, "# " + search, 1)
                    active += 1
                elif stripped.startswith("#") and search in stripped:
                    commented += 1
            if active > 0:
                content = "".join(lines)
                print("APPLIED: %s: commented out %s (%d line(s))" % (path, search, active))
                changed = True
            elif commented > 0:
                print("ALREADY: %s: %s already commented out" % (path, search))
            else:
                print("SKIPPED: %s: %s not found" % (path, search))

    if changed:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(content)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: python windows-v8-compat.py <v8_tree_root>\n")
        return 2
    root = argv[1]

    # The SDK the toolchain scripts hardcode: point them at the SDK
    # that is actually installed (10.0.26100.0).
    patch_file(os.path.join(root, "build", "vs_toolchain.py"), [
        ("replace", "'10.0.28000.0'", "'10.0.26100.0'"),
        # Skip copying dbghelp.dll when Debugging Tools for Windows
        # is not installed (it is optional for symbolization only).
        ("replace", "('dbghelp.dll', False)", "('dbghelp.dll', True)"),
    ])
    patch_file(os.path.join(root, "build", "toolchain", "win", "setup_toolchain.py"), [
        ("replace", "'10.0.28000.0'", "'10.0.26100.0'"),
    ])
    patch_file(os.path.join(root, "build", "config", "win", "BUILD.gn"), [
        # The 10.0.26100.0 SDK headers have no NTDDI_WIN11_BR macro.
        ("replace", '"NTDDI_VERSION=NTDDI_WIN11_BR"', '"NTDDI_VERSION=NTDDI_WIN10_NI"'),
        # Avoid __guard_* duplicate symbols against the mingw CRT.
        ("comment", 'cflags = [ "/guard:cf" ]', None),
        ("comment", 'cflags = [ "/guard:cf,nochecks" ]', None),
        # Desktop Windows builds against the dynamic CRT to match the
        # msvcrt.dll model the Zig mingw linker uses.
        ("replace", 'configs = [ ":static_crt" ]', 'configs = [ ":dynamic_crt" ]'),
    ])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
