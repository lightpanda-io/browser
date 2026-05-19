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

Bare `zig build` (without `make`) won't pick up the shim's `PATH` /
environment automatically — use `make test` / `make build-dev` for the
managed path. Direct `zig build` invocations need `PATH` and
`LIGHTPANDA_DARWIN_SDK_SHIM` set manually after `make darwin-sdk-shim`:

```bash
export LIGHTPANDA_DARWIN_SDK_SHIM="$PWD/.lp-cache/darwin-sdk-shim/sdk"
export PATH="$PWD/.lp-cache/darwin-sdk-shim/bin:$PATH"
zig build $V8 test
```

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
