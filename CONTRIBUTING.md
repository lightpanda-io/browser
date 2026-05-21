# Contributing

Lightpanda accepts pull requests through GitHub.

## Development

- Run the tests: `make test`
- Check formatting: `zig fmt --check ./*.zig ./**/*.zig`

See [AGENTS.md](AGENTS.md) for the full set of test, formatting, and code conventions (test filters, the leak-detection invariant, `@import` alias case, struct-init inference).

### Skip the V8 source build

`make build` and `make test` need V8. Without a prebuilt library, the build
compiles V8 from source, which takes several minutes. To skip that, reuse the
same prebuilt archive CI uses:

1. From the [`zig-v8-fork`
   releases](https://github.com/lightpanda-io/zig-v8-fork/releases), download the
   asset matching the `v8` and `zig-v8` versions pinned in
   [`.github/actions/install/action.yml`](.github/actions/install/action.yml):
   `libc_v8_<v8>_<os>_<arch>.a`.
2. Point the build at it via `ZIGFLAGS`, which the Makefile forwards to every
   `zig build`:

   ```sh
   ZIGFLAGS=-Dprebuilt_v8_path=/abs/path/to/libc_v8_<v8>_<os>_<arch>.a make test
   ```

   Export `ZIGFLAGS` in your shell to apply it to every build.

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
