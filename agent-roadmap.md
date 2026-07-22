# Lightpanda Agent — 6-month roadmap

## Positioning

Web automation carries two structural costs: **maintenance** (every script breaks when its site changes; the industry answer is headcount) and **weight** (a full Chrome per worker, plus a token bill on every action once an LLM is in the loop).

The Lightpanda agent attacks both: **describe the task once → get a deterministic script → it heals itself when the site changes → it runs at fleet scale** on a browser an order of magnitude lighter than Chrome — 6–22× less peak memory, ~10× faster launch-to-first-action (PandaScript-vs-CDP benchmark, July 2026). The LLM is paid at authoring and again only when a site changes; everything in between is free deterministic replay.

## Where we stand

Benchmarks follow-up, 2026-06-10:

|  | GAIA L1 acc | GAIA $/task | AB strict | AB $/task |
| :---- | ----: | ----: | ----: | ----: |
| **Native agent (fastgoto)** | **0.830** | **$0.34** | **0.697** | **$1.94** |
| agent-browser + Chrome (reference) | 0.830 | $1.03 | 0.455 | $3.21 |
| Lightpanda MCP (shipping) | 0.755 | $0.63 | 0.424 | $2.17 |

We match the best Chrome harness on GAIA at a third of its cost and beat everything measured on AssistantBench. The structural gap is **AB Hard** (0.526 strict, flat across every iteration); workstream 4 probes it with gated experiments.

## 1. Self-maintaining automations *(M1–M2)*

**Pain:** scrapers rot; re-fixing them is the dominant recurring cost of every scraping operation.

**Ship:** self-healing replay, working end-to-end on `agent-self-heal`: a degraded replay is detected from facts (thrown errors, empty results), the model judges breakage against the live page and repairs the script; the fix lands only after a fresh-session replay passes a deterministic cure check. Remaining for GA:

* Merge + docs (CLI help and lightpanda.io).
* Unattended operation: stable exit codes and a machine-readable heal report on stderr, so cron/CI replays alert when a script healed.
* Unattended safety: guard side-effectful validation replays; a review gate (or tool allowlist) on model-written diffs before a healed script re-enters cron — heal turns untrusted page content into code that runs with saved credentials.
* Heal telemetry; logged-in validation via profiles (workstream 2).

**Done:** a broken-script fixture corpus heals in CI; zero false heals over a week of scheduled replays; a launch post plus one external user's script healing in the wild.

**Why:** deletes the maintenance line item — the first complaint of every scraping buyer.

## 2. Authenticated sessions: profiles *(M2–M3)*

**Pain:** the valuable data sits behind logins; today every replay re-authenticates and cookies die with the process.

**Ship:** `--profile <dir>` unifying the existing primitives (`--cookie`/`--cookie-jar` JSON cookies, SQLite web storage) into one persistent identity — cookies plus local storage, periodic autosave. Profile dirs hold live credentials: created `0700`, documented as secret-equivalent. `/login` writes the profile; replays and heal validation run against it, closing workstream 1's logged-in gap. Session persistence for sites the user has credentials for — not anti-bot evasion.

**Done:** a login-gated fixture records once, replays authenticated across restarts, heals with the profile applied — and is the launch-post demo.

**Why:** logged-in workflows are the ones customers pay for.

## 3. Prompt to production scraper *(M3–M4)*

**Pain:** a finished script serves one input; "now do our 10,000 SKUs" means bespoke orchestration.

**Ship,** as a ladder:

* **Synthesis robustness:** save/replay holds under real use (quality floor), replay success tracked in CI.
* **Parameterization:** real script arguments beyond `$LP_*` placeholders.
* **Batch runner:** one script × an inputs file × N sessions. Primitives exist (isolated sessions, in-script parallel navigation); the runner — inputs file, bounded concurrency, per-row results — is new work.
* **Structured output:** `--task --output-schema <json>` for validated JSON. Greenfield.

**Done:** one command runs a saved script over a thousand-row input file with bounded concurrency and per-row results/errors — demoed in a launch post.

**Why:** fleet economics — the 6–22× memory advantage, monetized.

## 4. Quality & cost leadership, in public *(M1–M6, continuous)*

**Pain:** agent quality claims are unverifiable marketing; we win by publishing reproducible numbers.

**Ship:** the GAIA/AssistantBench harness stays the regression gate for every prompt and tool change (it took GAIA 0.698 → 0.830; the last iteration cut per-task cost 36%), results published against named stacks.

* **M1–M3, compounding wins:** pinned benchmark model versions (alias drift already caused one false regression), per-provider prompts, effort auto-tuning, cost guardrails.
* **M3–M6, hard-task experiments (opportunistic):** AB Hard is flat across every prompt iteration — model-bounded, and the kind of gap a model generation closes for free. Benchmark-gated probes only (plan-then-execute, a session scratchpad via the existing `lp.*` store, a web-search tool over zenai's search providers — Tavily today, Brave as an independent-index second provider); nothing here blocks the primary tracks.

Publishing note: shipping MCP ranks last in our own table until workstream 5 lands parity — follow-ups lead with the native agent.

**Done:** GAIA ≥0.85 at flat or lower $/task (AB Hard ≥0.60 as stretch); the suite runs on every merge; at least one public follow-up.

**Why:** reproducible numbers are the sales asset.

## 5. Ecosystem surface *(M4–M6)*

**Pain:** teams won't replace their agent stack, but they will plug a better browser into it.

**Ship:** MCP parity — replay and heal exposed over MCP so external agents get the full script lifecycle; the MCP transfer timeout closed (*network-thread half: browser team*); a static `submitForm`-style meta-tool on the existing form/semantic analysis; dynamic per-page tool exposure only as a benchmark-gated experiment (must beat its prompt-cache cost; fixed description templates so pages can't steer the tool channel).

**Done:** an MCP client drives save → replay → heal in CI; the timeout closed with a regression test; the lifecycle demonstrated from a real agent product (Claude Code).

**Why:** every MCP-speaking agent product is a channel, not a competitor.

## Quality floor

The agent-surface feedback pass burns down continuously: multi-line REPL and the `--save` extension fix are merged, remaining items are triaged fixed-or-declined, replay success is tracked in CI. Bugs live in the tracker.

## Timeline

Single owner: one primary track at a time, run serially; overlapping windows are hand-offs, not parallel delivery. Workstream 4 is the continuous gate for every prompt or tool change.

| Months | Primary track |
| :---- | :---- |
| M1–M2 | Self-heal GA |
| M2–M3 | Profiles (authenticated sessions) |
| M3–M4 | Prompt-to-production: robustness → parameterization → batch runner → structured output |
| M4–M6 | MCP parity & context-aware actions |
| M1–M6 | *Continuous:* benchmark gate + prompt wins; hard-task experiments from M3; quality-floor burndown |

## Risks & dependencies

* **Site reality:** bot-detection and site-compat gaps are the first objection to the production-scraper story. No evasion: failures surfaced honestly, compat gaps filed to the browser team, fixture targets chosen accordingly.
* **Browser team:** MCP timeout's network-thread half; profile autosave touchpoints; site-compat gaps; semantic-tree gaps from hard-task work.
* **Model churn:** deprecations invalidate benchmark baselines; pinning mitigates, at the cost of a re-baselining run.
* **Sequencing:** heal GA feeds the replay-success metric workstream 3 is judged by; profiles close heal's logged-in gap — slips cascade.
* **Single owner:** serial tracks, no slack to absorb slips. The benchmark gate is the first thing squeezed under pressure; it should be the last — it is both the regression gate and the public proof.
