# Lightpanda Agent — 6-month roadmap

## Where we stand

The native agent is the strongest Lightpanda configuration we have measured (benchmarks follow-up, 2026-06-10):

|  | GAIA L1 acc | GAIA $/task | AB strict | AB $/task |
| :---- | ----: | ----: | ----: | ----: |
| **Native agent (fastgoto)** | **0.830** | **$0.34** | **0.697** | **$1.94** |
| agent-browser \+ Chrome (reference) | 0.830 | $1.03 | 0.455 | $3.21 |
| Lightpanda MCP (shipping) | 0.755 | $0.63 | 0.424 | $2.17 |

* We match the best external harness on GAIA at a third of its cost, and beat everything on AssistantBench. The structural gap is **AB Hard (0.526, flat across every iteration)** — long multi-source research tasks that prompt tuning alone has not moved.  
* The roadmap has five workstreams. Two were already agreed (self-heal, system prompt); the other three come from the current feature surface: teammate feedback on the docs/REPL pass, known bugs, and what programmatic consumers need next.

## 1\. Self-healing replay — finish and GA *(M1–M2)*

Saved scripts are the product's compounding asset ("pay the LLM once, replay free forever"), and they rot when sites change. The heal feature — detect a silently degraded replay, have the model diagnose against the live page, validate the fix in a fresh session before touching the file — works today on the `agent-self-heal` branch, with save-time baselines and a deterministic cure-check that prevents fix-by-deletion.

**Remaining to call it done:**

* Merge, plus documentation in `docs/agent.md` and the tutorial.  
* Unattended operation: a stable `--heal` exit-code contract and a machine-readable heal report on stderr (like `$usage`), so cron/CI replays can alert when a script was healed.  
* Known limits: scripts that rely on a logged-in session cannot validate in a fresh session today (plan: detect recorded login steps, or an opt-in validate-with-cookies mode); heal-event telemetry.

**Done means:** a CI fixture corpus of deliberately broken scripts heals end-to-end; zero false heals on healthy scripts over a week of scheduled replays.

## 2\. Answer quality & agent CI — continuous *(M1–M6)*

The GAIA/AssistantBench harness is our regression gate for every prompt and tool change; an iteration on it took GAIA from 0.698 to 0.830, with the latest iteration alone cutting per-task cost 36%. Two phases:

* **M1–M3, compounding small wins:** pin benchmark model versions (preview-alias drift has already produced one false regression), per-provider prompt variants, effort auto-tuning (today's REPL-low/task-medium is static), and per-task cost guardrails.  
* **M3–M6, the Hard-task program:** AB Hard is bottlenecked on multi-source reasoning depth, not page speed. Levers: plan-then-execute prompting, a session scratchpad the model can write findings into (the `lp.*` store already exists for scripts — expose it to the LLM), and search-tool improvements.

**Done means:** AB Hard strict ≥0.60 (from 0.526) and GAIA ≥0.85 at flat or lower $/task; the regression suite runs on every merge.

## 3\. Script & replay robustness *(M2–M4)*

Improvements to the existing save/replay surface, driven by the internal feedback pass:

* **Bugs:** multi-line triple-quoted slash-command values don't work — the REPL has no line continuation, so the docs' multi-line `/extract '''…'''` example dies with "unterminated quote" (and that example also uses a `save=`\-first argument order the grammar rejects); the one-shot `--save` flag skips the `.js`\-append the REPL `/save` does. The "extracted data missing from the saved script" report did not reproduce — synthesis now derives the extract call even for sessions answered from page reads; watch it via the replay-success metric rather than fixing blind.  
* **Script iteration as a loop:** revising a saved script conversationally (`/load` → converse → `/save` update) mostly exists but is neither discoverable nor verified end-to-end — make it a first-class, documented flow.  
* **Parameterization:** replays currently take input only via `$LP_*` env placeholders; add proper arguments so one saved script serves many inputs.

**Done means:** replay success rate tracked on a fixture corpus in CI; every script-layer bug from the feedback pass closed.

## 4\. REPL & one-shot UX *(M3–M5, interleaved)*

* Progress reporting during `--task` (today it's silent until the answer).  
* Clarifying-questions mode: the agent asks before acting on underspecified tasks — opt-in flag first, promoted to default only if it earns it.  
* REPL polish: completion-cursor patch for the vendored line editor; the documentation fixes flagged in the feedback pass (quoting examples, `/save` synthesis modes, effort defaults table).

**Done means:** the feedback file is fully triaged — every line item fixed or explicitly declined — and one polished demo path exists for the launch post.

## 5\. MCP & programmatic consumers *(M4–M6)*

External agents (Claude Code and friends) drive Lightpanda over MCP; that surface should get the same script lifecycle the native agent has.

* Close the reported MCP transfer timeout from the agent side (*dependency: browser team* for the network-thread half).  
* Parity: expose replay and heal over MCP, so an external agent can save → replay → heal without the native LLM; keep the MCP `save` guidance in lockstep with agent synthesis.  
* Structured output for automation: `--task --output-schema <json>` so programmatic callers get validated JSON instead of prose.  
* Context-aware actions: a static `submitForm`\-style meta-tool built on the existing form/semantic analysis — typed, one-call page interactions (login, add-to-cart) that record and replay as stable primitives. Dynamic per-page MCP tool exposure (`tools/list_changed`) follows as an experiment on top, gated by the benchmark harness: it must not cost more in prompt-cache invalidation than it saves in turns, and synthesized descriptions use fixed templates so page content can't steer the tool channel.

**Done means:** an external-agent end-to-end test (MCP client drives save/replay/heal) in CI; the timeout closed with a regression test.

## Timeline

| Months | Focus |
| :---- | :---- |
| M1–M2 | Self-heal GA · benchmark harness automation \+ cheap prompt wins |
| M2–M4 | Script & replay robustness |
| M3–M5 | REPL/one-shot UX (small items, interleaved) |
| M4–M6 | MCP parity & structured output · Hard-task quality push |

## Risks & dependencies

* **Browser team:** the MCP timeout's network-thread half; any semantic-tree gaps the Hard-task work surfaces.  
* **Model churn:** provider model deprecations can invalidate benchmark baselines mid-stream; pinning (workstream 2\) mitigates but re-baselining costs a benchmark run (\~$80).  
* **Sequencing:** self-heal GA (workstream 1\) feeds the replay-success metric that workstream 3 is judged by; slippage there shifts M2–M4 right.