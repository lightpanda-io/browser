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
