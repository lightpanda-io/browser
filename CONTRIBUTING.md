# Contributing

Lightpanda accepts pull requests through GitHub.

## Development

- Run the tests: `make test`
- Check formatting: `zig fmt --check ./*.zig ./**/*.zig`

See [AGENTS.md](AGENTS.md) for the full set of test, formatting, and code conventions (test filters, the leak-detection invariant, `@import` alias case, struct-init inference).

### macOS 26+ (Apple silicon)

macOS 26's CommandLineTools SDK dropped `arm64-macos` from its system `.tbd`
exports — only `arm64e-macos` remains. Zig 0.15.x bundles a `libSystem.tbd`
that still has `arm64-macos` but is pinned to macOS 15.5, and its
auto-detection picks the higher-numbered system SDK. The arm64 link fails
with ~30 undefined `libSystem` / `CoreFoundation` / `SystemConfiguration`
symbols.

The Makefile detects this and builds a one-time SDK shim under
`.lp-cache/darwin-sdk-shim/` on the first `make test` / `make build-dev`
invocation: `usr/include` is symlinked from the system SDK,
`libSystem.tbd` is swapped for Zig's bundled copy, every other `.tbd` is
rewritten to also export `arm64-macos`. A repo-local `xcrun` wrapper is
prepended to `PATH` so Zig's SDK auto-detection lands on the shim.

> [!NOTE]
> The shim stays entirely inside the repo. It only **reads** the system SDK
> (the mirrored entries are symlinks pointing back at it) and writes the
> patched `.tbd` copies into `.lp-cache/` (gitignored). No `sudo`, no global
> install — nothing under `/Library`, `/usr`, or your Xcode / CommandLineTools
> install is modified. `make clean`, `make darwin-sdk-shim-clean`, or simply
> deleting `.lp-cache/` reverts it completely.

No action required from contributors — the shim builds in ~5 s the first
time and is reused on subsequent invocations. Re-run after Xcode
CommandLineTools updates or Zig version bumps:

```bash
make darwin-sdk-shim-clean   # remove the cached shim
make test                    # rebuilds the shim, then runs tests
```

Or rebuild explicitly without running tests:

```bash
make darwin-sdk-shim
```

`make clean` also wipes the shim. On macOS 15 or older, on Linux, or on any
future SDK that puts `arm64-macos` back, the shim block is skipped entirely
and the Makefile behaves exactly as before.

This is a temporary workaround for Zig 0.15.x. Upgrading the project to
Zig 0.16+ (its bundled libc ships the macOS 26 SDK and links `arm64-macos`
natively) makes the shim unnecessary — at that point remove this section,
`scripts/darwin-sdk-shim.sh`, and the Makefile block. It won't switch itself
off when that happens: detection keys off the *system* SDK, which still lacks
`arm64-macos` on macOS 26, so removal is a deliberate step tied to the
toolchain bump.

Bare `zig build` (without `make`) won't pick up the shim's `PATH` /
environment automatically — use `make test` / `make build-dev` for the
managed path. Direct `zig build` invocations need `PATH` and
`LIGHTPANDA_DARWIN_SDK_SHIM` set manually after `make darwin-sdk-shim`:

```bash
export LIGHTPANDA_DARWIN_SDK_SHIM="$PWD/.lp-cache/darwin-sdk-shim/sdk"
export PATH="$PWD/.lp-cache/darwin-sdk-shim/bin:$PATH"
zig build $V8 test
```

### Skip the V8 source build

By default the build compiles V8 from source, which takes several minutes. Run
`make download-v8` once to fetch the matching prebuilt archive from the
[`zig-v8-fork`](https://github.com/lightpanda-io/zig-v8-fork/releases) releases
instead; later `make build` / `make test` pick it up automatically.

## Before opening a PR

- [ ] Tests pass (`make test`).
- [ ] Formatting is clean (`zig fmt --check ./*.zig ./**/*.zig`).
- [ ] CLA signed (see below).

## CLA

You have to sign our [CLA](CLA.md) during your first pull request process
otherwise we're not able to accept your contributions.

The process signature uses the [CLA assistant
lite](https://github.com/marketplace/actions/cla-assistant-lite). You can see
an example of the process in [#303](https://github.com/lightpanda-io/browser/pull/303).
