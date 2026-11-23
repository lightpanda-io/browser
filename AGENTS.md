# AGENTS.md

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to open a pull request (CLA, dev setup, pre-PR checks).

## Build and tests

Run `make download-v8` once first: it fetches the prebuilt V8 archive into `.lp-cache/`, which `build.zig` picks up automatically. Without it every build compiles V8 from source (10+ minutes).

The C and Rust dependencies are built with `-Doptimize=fast` whatever `-Doptimize` is, so debug and release builds share them. Pass `ZIGFLAGS=-Ddebug_deps` to step into a dependency with a debugger.

```bash
make test                                       # Run all tests
make test F="server"                            # Filter by substring
TEST_FILTER="WebApi: #selector_all" make test   # Filter main + subtest (separator: #)
TEST_VERBOSE=true make test
TEST_FAIL_FIRST=true make test
METRICS=true make test                          # Capture allocation/duration metrics as JSON
TEST_JOBS=1 make test                           # Run in one process (default: up to 4, or 1 when filtered)
```

The custom test runner (`src/test_runner.zig`) detects memory leaks in debug builds. **A test that allocates without freeing fails** — not just lints.

The suite is split across processes that run at the same time, each claiming the next test not yet taken. So a test can't rely on an earlier one having run, and files it writes go in `std.testing.tmpDir`, never a fixed path. Each process binds its test servers to ephemeral ports; fixtures keep addressing `127.0.0.1:9582` / `localhost:9582` (HTTP) and `:9584` (WebSocket), which libcurl routes to the real ones.

## Formatting

```bash
make fmt    # Exact command CI runs
```

`zig build` depends on the fmt step, so a local build catches drift too.

## Conventions

Mirror the patterns in neighboring files. In particular:

- `@import` alias case follows the imported file's basename (`const Frame = @import("Frame.zig")`, `const ast = @import("ast.zig")`).
- Prefer struct-init type inference (`.{ ... }`) where the expected type is known from the function signature or variable annotation.

## Object lifetimes

A realm (`js.Context`) is destroyed when its frame navigates or its worker goes away, while another frame can still hold, and call, the objects that were created in it. A navigation re-initializes the `Frame` struct in place, so a `*Frame` kept from before it names the next document, and a kept `*Execution` points into freed memory.

- An object that outlives the call that created it doesn't store a `*Frame`, a `*Execution`, a `*js.Context` or anything they own (scheduler, call arena, `url`, ...). It stores a handle (`src/browser/js/handle.zig`): `_frame: js.FrameHandle` from `frame.handle()`, or `_exec: js.ExecutionHandle` from `exec.handle()`.
- A handle has no realm to misuse: `get()` (the `*Frame` or `*Execution`) and `js()` (the `*js.Context`) return null once the realm is gone. A `FrameHandle` names the document the frame had when it was taken: after a navigation it resolves to null, not to the next document.
- What outlives the realm needs no check: `handle.page()`, and through it the factory and the page arena. A scheduler task's finalizer runs when its realm is already gone, so it releases through that.
- `ExecutionHandle.global()` is the `Frame` or `WorkerGlobalScope` of the realm, which an isolated world can be destroyed before. An object linked in a list its global owns is unlinked through it.
- Decide what each use does when the handle resolves to null (throw, ignore, leave a promise pending), check it against Chrome, and add the case to `src/browser/tests/frames/navigated_realm_*.html`.
- `frame: *Frame` and `exec: *Execution` as parameters are fine: the bridge passes the realm that is running. For a method of an object whose realm is gone, that is the caller's.

What still keeps a pointer, and why it can't go stale: `Document._frame` (an optional, set by `Frame.init` and cleared by `Frame.deinit`), `Worker._worker_scope` (an optional, cleared by `Worker.deinit`), a task struct that keeps the realm whose scheduler it is queued on (it only runs while that realm exists, and is finalized before the realm is freed), `Media._clock` (cleared by its task's finalizer), and structs that live for a single call (walkers, parsers).
