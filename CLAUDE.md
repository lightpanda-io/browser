# Project Overview

Lightpanda is a headless browser written in Zig for automation, agents and testing. It provides a V8-based JS runtime, a DOM implementation, a libcurl-backed network stack, and a CDP/MCP protocol surface so it can be driven by tools like Puppeteer/chromedp or by an LLM-driven toolset. Intended usage: CLI (fetch, serve), an embeddable library surface (lp.* re-exports) and protocol servers (CDP and MCP).

# Key Components

- build.zig:build (build graph, links V8, libcurl, html5ever Rust crate and defines targets snapshot_creator/test/run steps)
- src/main.zig:main, run (CLI entry; modes: serve, fetch, mcp)
- src/App.zig:App:init / deinit (global runtime owner: Network, Telemetry, ArenaPool, V8 Env)
- src/network/Network.zig:init / run / deinit (global network event loop, connection pools, curl allocator)
- src/network/http.zig:Connection.reset / setMethod / HeaderIterator (libcurl-easy wrapper and header helpers)
- src/browser/HttpClient.zig:Client / request / processOneMessage (high-level HTTP client used by Page)
- src/browser/Page.zig:init / navigate / deinit (page/frame lifecycle, cookie_origin propagation)
- src/browser/ScriptManager.zig:addFromElement / evaluate (script loading/evaluation ordering)
- src/browser/Runner.zig:wait / waitForSelector / waitForScript (wait/tick loop used across CLI and protocols)
- src/ArenaPool.zig:init / acquire / release (alloc arena pooling used widely in runtime and tests)
- src/SemanticTree.zig:walk / getNodeDetails / jsonStringify (DOM semantic serialization for CDP/MCP)
- src/Server.zig:init / spawnWorker / Client.httpLoop (CDP websocket server and per-connection CDP lifecycle)
- src/cdp/CDP.zig:dispatch / BrowserContext lifecycle (CDP message parsing and domain dispatch)
- src/cdp/domains/* (page.zig, network.zig, lp.zig): domain handlers implementing CDP RPCs
- src/mcp/protocol.zig / src/mcp/router.zig / src/mcp/tools.zig: MCP protocol shapes, routing and agent-facing tools
- src/network/cache/FsCache.zig / src/network/cache/Cache.zig: disk cache implementation and caching policy
- src/lightpanda.zig:fetch (CLI-driven one-shot navigation + dump), RC(meta-type), re-exports
- src/log.zig: structured logging (logfmt/pretty) used across the project

# Architecture

    CLI/Client (main.zig)               MCP clients / Tools
          │                                     │
          ▼                                     ▼
    App (src/App.zig)  ──▶ Network (libcurl) ──▶ HttpClient ──▶ Page/ScriptManager ──▶ V8/Context
          │                                     │
          └─────────▶ CDP Server (src/Server.zig) ─▶ CDP dispatcher (src/cdp/CDP.zig) ─▶ domains

- App owns ArenaPool, Network, Telemetry, Env (V8). 
- Network supplies connections to HttpClient which serves Page navigation and resource loading. 
- Page + ScriptManager run JS in V8 via Context created by Env. 
- Server accepts WebSocket/CDP clients and delegates JSON messages to CDP.zig which routes to domain handlers.

# Core Data Structures

- src/App.zig:App — global owner; App.config and App.arena_pool are critical lifetimes.
- src/ArenaPool.zig:ArenaPool / Entry — pooled std.heap.ArenaAllocator instances (acquire/release invariants).
- src/network/http.zig:Connection / HeaderIterator — curl easy wrapper; Connection.transport union required for mixed transports.
- src/network/cache/Cache.zig:CachedMetadata / CacheRequest — canonical cache policy model (use tryCache to decide caching).
- src/cdp/CDP.zig:BrowserContext / Command — arena-backed per-message allocators and registry mapping.
- src/browser/Runner.zig:Runner / TickOpts — scheduling and wait semantics for navigation readiness.
- src/lightpanda.zig:RC(comptime T) — simple reference-counting meta-type used across native objects.

# Control Flow (typical fetch/serve)

1. CLI: src/main.zig parses args and calls run().
2. run() constructs App via src/App.zig:init which creates Network, Env (V8), Telemetry, ArenaPool.
3a. serve mode: src/Server.zig:init binds listener; spawnWorker accepts connections and upgrades HTTP->WebSocket, creating Client and CDP session.
3b. fetch mode: src/lightpanda.zig:fetch builds Browser/Session/Page, navigates via Page.navigate and waits via Runner.wait; dumps output (html/markdown/semantic_tree/wpt).
4. Page navigation triggers HttpClient.request which uses Network/Connection to perform libcurl transfers; responses are fed back to page (scripts/XHR/fetch) and ScriptManager evaluates scripts in Context.
5. CDP/MCP protocol handlers (src/cdp/* and src/mcp/*) inspect pages via SemanticTree, Interactive, Forms and perform actions (click/fill) via src/browser/actions.zig.

# Test-Driven Development

- Unit tests: run `zig build test` or `make test` (Makefile wraps zig test with filtering). Many modules include per-file tests you can run: e.g. `zig test src/ArenaPool.zig`, `zig test src/browser/Runner.zig -q`.
- Web-api tests: harness in src/testing.zig provides htmlRunner/runWebApiTest helpers. End-to-end requires demo and WPT setup (see README).
- When editing: run `zig build test` first; for changes touching V8/snapshot, use `zig build snapshot_creator` then `zig build -Dsnapshot_path=...`.

# Bash Commands

- Build (release fast + embedded snapshot): make build
- Build (debug): make build-dev
- Run locally (after build): ./zig-out/bin/lightpanda [serve|fetch ...]
- Run a quick CLI: zig build run
- Run tests (full): make test  (invokes `zig build test -freference-trace`)
- Build snapshot: zig build snapshot_creator -- src/snapshot.bin
- Build using snapshot: zig build -Dsnapshot_path=../../snapshot.bin
- End-to-end demo runner (requires ../demo): make end2end
- Docker run (nightly): docker run -d --name lightpanda -p 127.0.0.1:9222:9222 lightpanda/browser:nightly

# CI

Workflows are under .github/workflows:
- zig-test.yml runs `zig build test` (unit test matrix). 
- e2e-test.yml, e2e-integration-test.yml, wpt.yml and nightly.yml: end-to-end and nightly flows (run browser with snapshot and WPT/demo). 
- cla.yml checks contributor CLA.

# Code Style / Conventions (non-obvious)

- Use arena allocators for short-lived buffers: many APIs expect an arena; returned slices often borrow those arenas — preserve allocator lifetimes (Page.getArena / releaseArena).
- Pass App pointer into subsystems when required (Network, Page/Session patterns). Many init functions expect allocator + parent pointers.
- Debug-only checks live behind builtin.mode == .Debug; leak/double-free detectors in ArenaPool and other modules only run in Debug mode.
- Use JsonStringify/Std.json with cmd.arena / message_arena when constructing protocol responses — arena resets are used per-message.

# Gotchas (common pitfalls & fixes)

- Zig toolchain version: build.zig enforces minimum Zig. Do not bypass that compile-time check.
- Arena lifetime mistakes: do not return slices allocated in a transient arena (e.g., cmd.arena) after the arena is reset. Reference: src/browser/forms.zig:collectForms requires an arena allocator that outlives consumer.
- Changing struct Field layout: ArenaPool.Entry relies on field name 'arena' and @fieldParentPtr used in release/reset.
- Network/curl allocator: ZigToCurlAllocator.Block layout/alignment is fragile; do not change Block size/alignment without updating pointer math in src/network/Network.zig and sys/libcurl.zig.
- V8 handle lifetimes: Context.trackGlobal/trackTemp moved to Session-level storage; do not revert to context-local tracking (see src/browser/js/Context.zig and Session.zig).
- CDP startup special-case: sessionId "STARTUP" handling in src/cdp/CDP.zig is required for some drivers; don’t remove.
- Runner wait semantics: Runner._wait may return .done for timeouts (not an error); tools must map .done to appropriate message (see tools changes).

# Pattern Examples

- Using an arena for temporary allocations:
  - src/SemanticTree.zig:jsonStringify(arena, ...) — pass and use arena for visitor allocations.
- Safe acquire/release patterns:
  - src/ArenaPool.zig:acquire / release — reset the arena outside the mutex then lock to enqueue.
- Network connection reset:
  - src/network/http.zig:Connection.reset(config, ca_blob) — always call reset when reusing connections, do not assume old curl state.

# Common Mistakes -> Fixes

- Symptom: Use-after-free on strings returned by an RPC.
  Fix: Ensure the allocator used (cmd.arena or page_arena) is not reset before the response is sent. See src/cdp/CDP.zig:processMessage and arena.reset patterns.

- Symptom: Tests failing only in CI but not locally.
  Fix: Reproduce with `zig build test` (CI uses this). Check for environment-dependent features: snapshot embedding, external demo repo required for e2e.

- Symptom: Unexpected CDP node id mismatches.
  Fix: Use centralized registry: src/cdp/domains/lp.zig:interactive.registerNodes and avoid duplicate registrations.

# Invariants

- init/deinit symmetry: init allocates resources, deinit must free them in reverse order (examples: Env.createContext / Context.deinit; BrowserContext deinit order in CDP.zig).
- Arena owners must outlive slices borrowed by consumers (page_arena for page-scoped data, cmd.arena for single-message data).
- All getConnection() calls must have a matching releaseConnection() in every control path.

# Anti-patterns

- Holding an arena pointer beyond its scoped lifetime (do not stash page.call_arena allocations into session-global structs).
- Mutating connection/curl options on in-flight handles without ensuring no active transfers.
- Replacing centralized registry/registerNodes logic with ad-hoc node id generation.

# Useful pointers when changing code

- If you change CLI flags or default logging, update src/main.zig and README examples.
- When editing network/curl code, run `make test` and at least the network/http and cache FsCache tests (e.g. `zig test src/network/cache/FsCache.zig`).
- When changing CDP domain payload formats, update tests under src/cdp and src/cdp/testing.zig and ensure socket framing expectations in that harness remain intact.

---

If you want, I can also generate a short checklist for modifying a specific area (e.g., Network/curl, V8 Context lifecycle, or CDP domain) with exact tests and files to run.

# Verification Checklist

- Run the full test matrix locally or in CI
- Confirm failing test fails before fix, passes after
- Run linters and formatters

# Test Integrity

- NEVER modify existing tests to make your implementation pass
- If a test fails after your change, fix the implementation, not the test
- Only modify tests when explicitly asked to, or when the test itself is demonstrably incorrect

# Suggestions for Thorough Investigation

When working on a task, consider looking beyond the immediate file:
- Test files can reveal expected behavior and edge cases
- Config or constants files may define values the code depends on
- Files that are frequently changed together (coupled files) often share context

# Must-Follow Rules

1. Work in short cycles. In each cycle: choose the single highest-leverage next action, execute it, verify with the strongest available check (tests, typecheck, run, lint, or a minimal repro), then write a brief log entry of what changed + what you'll do next.
2. Prefer the smallest change that can be verified. Keep edits localized, avoid broad formatting churn, and structure work so every change is easy to revert.
3. If you're missing information (requirements, environment behavior, API contracts), do not assume. Instead: inspect code, read docs in-repo, run a targeted experiment, add temporary instrumentation, or create a minimal reproduction to learn the truth quickly.


# Index Files

I have provided an index file to help navigate this codebase:
- `.claude/docs/general_index.md`

The file is organized by directory (## headers), with each file listed as:
`- `filename` - short description. Key: `construct1`, `construct2` [CATEGORY]`

You can grep for directory names, filenames, construct names, or categories (TEST, CLI, PUBLIC_API, GENERATED, SOURCE_CODE) to quickly find relevant files without reading the entire index.

**MANDATORY RULE — NO EXCEPTIONS:** After you read, reference, or consider editing a file or folder, you MUST run:
`python .claude/docs/get_context.py <path>`

This works for **both files and folders**:
- For a file: `python .claude/docs/get_context.py <file_path>`
- For a folder: `python .claude/docs/get_context.py <folder_path>`

This is a hard requirement for EVERY file and folder you touch. Without this, you'll miss recent important information and your edit will likely fail verification. Do not skip this step. Do not assume you already know enough. Do not batch it "for later." Do not skip files even if you have obtained context about a parent directory. Run it immediately after any other action on that path.

The command returns critical context you cannot infer on your own:

**For files:**
- Edit checklist with tests to run, constants to check, and related files
- Historical insights (past bugs, fixes, lessons learned)
- Key constructs defined in the file
- Tests that exercise this file
- Related files and semantic overview
- Common pitfalls

**For folders:**
- Folder role and responsibility in the codebase
- Key files and why they matter
- Cross-cutting behaviors across the subtree
- Distilled insights from every file in that folder

**Workflow (follow this exact order every time):**
1. Identify the file or folder you need to work with.
2. Run `python .claude/docs/get_context.py <path>` and read the output.
3. Only then proceed to read, edit, or reason about it.

If you need to work with multiple paths, run the command for each one before touching any of them.

**Violations:** If you read or edit a file or folder without first running get_context.py on it, you are violating a project-level rule. Stop, run the command, and re-evaluate your changes with the new context.



---
*This knowledge base was extracted by [Codeset](https://codeset.ai) and is available via `python .claude/docs/get_context.py <file_or_folder>`*
