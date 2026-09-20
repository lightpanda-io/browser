---
artifact_type: session-summary
status: historical
project: browser
date: 2026-09-20
aggregation: daily
---

# Touch-input review and regression results

Review target: merge base `e3aa36f83a7ffc70438cd2fd52fa470c850da44b` through
`8fb3f0c0330f92b18acbddeed94d05787dddc3ac`, followed by the fixes described below.
The populated `touchCancel` rejection was already committed at review start.

## Findings addressed

- **P2: Preserve modifier keys on CDP touch events.** `Input.dispatchTouchEvent`
  ignored the client's `modifiers` field, and the shared dispatcher supplied no
  modifier options. A modified gesture therefore reached application handlers
  with all four flags false. Each command now supplies its own flags, including
  empty end/cancel requests; omitted flags default to false. WebDriver touch
  dispatch also forwards its existing keyboard modifier state.
- **Adjacent existing defect: identify WebDriver touch pointers as touch.**
  The helper hard-coded `pointerType = "mouse"` before this branch. It now
  receives the source type for moves, presses, and releases, including captured
  moves/releases. Mouse sources retain `"mouse"`. This is the bounded follow-up
  identified in the earlier review, not a regression introduced by this branch.

Contracts: [CDP Input definition](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)
and [Pointer Events pointerType](https://w3c.github.io/pointerevents/#dom-pointerevent-pointertype).

## Verification

- `make download-v8`: existing matching prebuilt archive ready.
- Before new assertions: `TEST_FILTER='cdp.input: dispatchTouchEvent' make test`
  passed 18/18; `TEST_FILTER='WebApi: WebDriver' ZIGFLAGS='-Dwpt_extensions' make test`
  passed 6/6.
- Before production fixes, both focused regressions compiled and failed:
  `cdp.input: dispatchTouchEvent preserves each event's modifier keys` and
  `WebApi: WebDriver touch actionSequence populates touches`.
- `zig fmt --check ./*.zig ./**/*.zig`: passed.
- `ZIGFLAGS='-Dwpt_extensions' make test`: **1589/1589 passed**, 5 skipped.
- `make build-dev`: passed; built `1.0.0-dev.9596+8fb3f0c03` with the working
  source fixes. The source diff SHA-256 recorded by the runtime collector is
  `0d93107f3c7bad1968adc57637bc73665cd82e2ee35c26e41a8cb8a92a79953d`.
- Real-client collector:
  `node /Users/jr/Dev/GH_PRs/lightpanda/touch-eval-pack/runner/suite_b.mjs --mode local --binary /Users/jr/Dev/GH_PRs/lightpanda/browser/zig-out/bin/lightpanda --repo /Users/jr/Dev/GH_PRs/lightpanda/browser --run-id touch-review-20260920 --out /private/tmp/lp-touch-review.o9Ak4a/smoke`.
- Comparator:
  `node /Users/jr/Dev/GH_PRs/lightpanda/touch-eval-pack/runner/compare.mjs /private/tmp/lp-touch-review.o9Ak4a/smoke`.
  Lightpanda: 111 passing assertions, 11 failing, 1 not applicable. Chrome:
  121 passing, 2 not applicable. Parity: 12 failures and 6 known divergences.
  These are assertion counts, not test-case counts; exit 0 does not mean full
  browser parity. Populated-cancel rejection and no emitted cancellation event
  passed for both clients and both engines. The collector's `step_error` for
  that negative case is expected.
- `node /private/tmp/lp-touch-review.o9Ak4a/modifiers.mjs`: **4/4 passed**
  (Puppeteer and Playwright, each against Lightpanda and Chrome). It exercises
  each modifier bit, all bits together, omission/default reset, and start,
  move, end, and cancel. The move exceeds Chrome's small-movement threshold.

Clients: puppeteer-core 25.11.0 and playwright-core 1.63.0; reference Chrome
153.0.8010.52. Raw/normalized traces and comparison are under
`/private/tmp/lp-touch-review.o9Ak4a/smoke/`; the modifier probe and results are
under `/private/tmp/lp-touch-review.o9Ak4a/`. These are temporary local artifacts.
The initial sandboxed Zig attempt ran no tests because cache/toolchain access
was denied; all successful Zig and browser commands used elevated local access.

## Remaining compatibility limits

The prior real-client run already reported a Playwright selector-tap timeout
and missing CDP touch-derived pointer/mouse/click events. Those wider behavior
changes are outside these modifier/source-type fixes. Single-contact support,
the deferred JavaScript Touch constructor, and existing synthetic-layout
limitations are unchanged. The new smoke run reproduces the prior failure
counts: ordinary Playwright `page.tap` times out, and CDP taps emit touch events
without the pointer/mouse/click streams. Forced selector tap remains a diagnostic,
not a passing substitute for the ordinary API. Comparing failure identities
(`scenario`, `client`, `browser`, `assertion`) against the prior
`2026-09-20-local-864f3cf1d-wt-r4` run found **zero added and zero removed**:
the same 11 Lightpanda assertions and 12 parity assertions fail.

## Preserved state

The untracked `reviews/2026-09-18-arrufat-review-fixes-audit.md`, `src/.DS_Store`,
and `src/browser/tests/.DS_Store` were preserved and excluded from staging.
No push is authorized or planned.

Next action: review the local commit for the touch PR; track selector hit-testing
and touch-derived pointer/click delivery as separate compatibility work.
