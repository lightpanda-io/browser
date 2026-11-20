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

A realm (`js.Context`) is torn down when its frame navigates or is removed, but another frame can still hold objects that were created in it. A navigation re-initializes the `Frame` struct in place, so a `*Frame` kept from before it names the next document.

- A web API object doesn't keep a `*Frame`. It keeps its realm, `_exec: *js.Execution`, taken from `&frame.main_js.execution` (during a call `frame.js` is the calling world's context, and an isolated world can go before its frame does).
- It reaches the frame through `exec.frame()`, which is null once the realm is gone. Decide what the API does then, check it against Chrome, and add the case to `src/browser/tests/frames/navigated_realm_objects.html`.
- `*Frame` as a parameter is fine: the bridge passes the frame of the realm that is running.
- Once a realm is gone, `Execution`'s event methods (`dispatch`, `registerListener`, `setHandler`, ...) do nothing and `Scheduler.add` fails with `error.SchedulerClosed`. Its other methods still forward to the frame.
- A scheduler task's finalizer runs after the realm is marked gone, so it releases through `_exec.page` and `_exec._factory`.

What still keeps a `*Frame`: `Window` (one per frame, re-initialized with it), `Document._frame` (set by `Frame.init`, cleared by `Frame.deinit`), `WorkerGlobalScope._frame` (the frame that owns the worker), and task or walker structs that belong to a frame's scheduler or to a single call.
