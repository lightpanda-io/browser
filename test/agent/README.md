# Agent regression suite

End-to-end regression tests for `lightpanda agent`. Two layers, so the cheap
deterministic checks can gate every PR while the expensive keyed checks run
nightly / on demand.

```
test/agent/
  run.sh                 orchestrator (bash + jq)
  fixtures/              static HTML served locally over HTTP
    facts/company.html   closed-form Q&A page
    hn/front.html        frozen HN front page
    hn/item-*.html       frozen HN comment threads
  scripts/hn-front.js    golden PandaScript (replays against the fixtures)
  golden/hn-front.json   exact expected replay output
  cases/static-qa.tsv    <task>\t<expected-substring> per line
  cases/hn-live.task     task prompt for the live HN case (pins the contract)
  schemas/hn-live.jq     shape invariant for the live HN output
```

## Layers

### Deterministic (no API key, runs on every PR)

Replays `scripts/hn-front.js` — a top-5-stories / top-3-comments HN scrape
pointed at the local fixture server — and diffs the returned JSON **exactly**
against `golden/hn-front.json`. This guards the replay engine and the
`goto` / `extract` primitives. No LLM, no network.

### Live (needs `GOOGLE_API_KEY` or `GEMINI_API_KEY`, runs nightly / on demand)

Drives the real Gemini-backed agent:

- **Static Q&A** — for each row in `cases/static-qa.tsv`, run
  `lightpanda agent --task "<question about a local fixture>"` and assert the
  expected substring appears in the answer. Closed-form answers make the
  substring match robust to LLM phrasing.
- **HN save + replay** — ask the agent (task in `cases/hn-live.task`) to
  scrape live Hacker News and `/save` a reproducible script, then replay that
  script **token-free** and validate the output against `schemas/hn-live.jq`
  (a *shape* invariant: exactly 5 stories, non-empty titles, ≤3 comments each
  with non-empty `user`/`text`). We can't assert exact values because the live
  site and the LLM both vary — so the task prompt pins the output contract and
  the schema verifies it; edit those two files together.

The stable `$usage total=N` line lightpanda prints to stderr is captured per
task; a loose `MAX_TOKENS` ceiling flags a runaway agent loop.

## Running locally

```bash
make build                       # produces zig-out/bin/lightpanda
make test-agent                  # all layers (live skipped if no key)
make test-agent LAYER=deterministic

# or invoke run.sh directly:
./test/agent/run.sh deterministic
GEMINI_API_KEY=... ./test/agent/run.sh live
```

Environment knobs (see the header of `run.sh`): `LPD`, `LP_MODEL`,
`LP_HTTP_PROXY`, `MAX_TOKENS`. The fixture-server port (8081) is part of the
fixture contract — the golden script and TSV embed it — and is not
configurable.

## CI

- `.github/workflows/e2e-test.yml` runs the **deterministic** layer on every PR
  (job `agent-deterministic`).
- `.github/workflows/agent-regression.yml` runs **all** layers nightly and via
  *Run workflow* (`workflow_dispatch`). It uses the `GEMINI_API_KEY` repo secret;
  it reuses the `MASSIVE_PROXY_RESIDENTIAL_US` secret as `LP_HTTP_PROXY` for the
  live HN call (datacenter IPs are often blocked by news.ycombinator.com).

## Maintenance

- **Add a Q&A case:** append a `<task>\t<expected>` row to
  `cases/static-qa.tsv` (point the task at a `fixtures/` page).
- **Change the deterministic scrape:** edit `scripts/hn-front.js` and/or the
  `fixtures/hn/*` pages, then regenerate the golden:
  ```bash
  ./test/agent/run.sh update-golden
  ```
  Review the diff before committing — the golden is the contract.
