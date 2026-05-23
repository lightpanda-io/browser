# Contributing

Lightpanda accepts pull requests through GitHub.

## Development

- Run the tests: `make test`
- Check formatting: `zig fmt --check ./*.zig ./**/*.zig`

See [AGENTS.md](AGENTS.md) for the full set of test, formatting, and code conventions (test filters, the leak-detection invariant, `@import` alias case, struct-init inference).

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

## Test Output

When a test fails with a memory leak error, the output shows which test leaked.
Run with `TEST_VERBOSE=true make test` for detailed allocation tracking.

## Troubleshooting

**Build fails with "unknown target" error?**
- Check `zig version` matches the project's expected version
- Run `zig env` to see the current target triple
- On macOS Apple Silicon, ensure Rosetta 2 is installed if building x86 binaries

**V8 download fails or times out?**
- Check your internet connection and proxy settings
- Try manually downloading from https://github.com/lightpanda-io/zig-v8-fork/releases
- Place the archive in the expected download directory

**Tests fail with "memory leak" error?**
- The test runner in debug builds detects any unfreed allocations
- Run `make test` with `TEST_VERBOSE=true` to see which test leaks
- Check that all allocated resources are properly freed
