# Contributing

Lightpanda accepts pull requests through GitHub.

## Development

- Run the tests: `make test`
- Check formatting: `make fmt`

See [AGENTS.md](AGENTS.md) for the full set of test, formatting, and code conventions (test filters, the leak-detection invariant, `@import` alias case, struct-init inference).

### Skip the V8 source build

By default the build compiles V8 from source, which takes several minutes. Run
`make download-v8` once to fetch the matching prebuilt libraries from the
[`zig-v8-fork`](https://github.com/lightpanda-io/zig-v8-fork/releases) releases
instead; later `make build` / `make test` pick them up automatically. On Linux
x86_64 this includes the shared flavor (`libc_v8.so`) used by `-Ddev_fast`
builds (defaults to true). Pass `-Ddev_fast=false` to get a static-V8 debug
build instead.

## Discuss large changes first

Bug fixes and small, self-contained improvements can go straight to a PR. For
larger changes, open an issue which describes what you want to change, why
and how you intend to implement it. We welcome AI-assisted or driven PRs,
but try to provide a short summary in your own words. Wait for a maintainer
to agree on the issue/approach before submitting a PR.

"Large" is more about what a change touches. Open an issue first if your change:

- adds a new feature area (e.g. CSS animations, a new Web API family, a new
  CDP domain, a new CLI flag),
- changes how an existing pipeline works (resource loading, scheduling, the
  event loop, script execution, style/layout, memory management),
- adds work that runs on every page, even pages that don't use the feature,
- adds a dependency,
- is a refactor spanning many files,
- or is more than a few hundred lines, not counting tests.

We may already be working in that area, have a different design in mind, or
have reasons not to take the change at all. A short conversation up front saves
you from writing code we can't merge, and saves us from having to review a
design while it's already written.

Large PRs opened without a prior discussion are likely to be closed.

## Real-world impact

If possible, when opening an issue or a PR, include real-world examples, e.g.
a site that breaks or a library that depends on specific behavior. Spec
compliance that no site depends on can add overhead and complexity to the
codebase.

## Before opening a PR

- [ ] Tests pass (`make test`).
- [ ] Formatting is clean (`make fmt`).
- [ ] CLA signed (see below).
- [ ] For a large change: discussed in an issue first.
- [ ] Real-world example included where possible (site, library, or script).

## CLA

You have to sign our [CLA](CLA.md) during your first pull request process
otherwise we're not able to accept your contributions.

The process signature uses the [CLA assistant
lite](https://github.com/marketplace/actions/cla-assistant-lite). You can see
an example of the process in [#303](https://github.com/lightpanda-io/browser/pull/303).
