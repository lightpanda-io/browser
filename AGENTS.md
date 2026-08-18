# AGENTS.md

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to open a pull request (CLA, dev setup, pre-PR checks).

## Build and tests

Run `make download-v8` once first: it fetches the prebuilt V8 archive into `.lp-cache/`, which `build.zig` picks up automatically. Without it every build compiles V8 from source (10+ minutes).

```bash
make test                                       # Run all tests
make test F="server"                            # Filter by substring
TEST_FILTER="WebApi: #selector_all" make test   # Filter main + subtest (separator: #)
TEST_VERBOSE=true make test
TEST_FAIL_FIRST=true make test
METRICS=true make test                          # Capture allocation/duration metrics as JSON
```

The custom test runner (`src/test_runner.zig`) detects memory leaks in debug builds. **A test that allocates without freeing fails** — not just lints.

## Formatting

```bash
zig fmt --check ./*.zig ./**/*.zig    # Exact command CI runs
```

`zig build` depends on the fmt step, so a local build catches drift too.

## Conventions

Mirror the patterns in neighboring files. In particular:

- `@import` alias case follows the imported file's basename (`const Frame = @import("Frame.zig")`, `const ast = @import("ast.zig")`).
- Prefer struct-init type inference (`.{ ... }`) where the expected type is known from the function signature or variable annotation.
