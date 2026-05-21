# Agent mode

> Looking for a step-by-step walkthrough instead of a reference?
> See [agent-tutorial.md](agent-tutorial.md) — it builds one end-to-end
> Hacker News scenario covering the REPL, recording, replay,
> `--self-heal`, and the MCP roundtrip.

`lightpanda agent` runs a browsing agent backed by Lightpanda's headless engine.
It can act as:

- an **LLM agent** that drives the browser with tool calls (`--provider`),
- a **scripted runner** that replays a `.lp` script deterministically,
- a **basic REPL** for hand-driven PandaScript with no LLM at all,
- a **one-shot task runner** that prints a single answer to stdout (`--task`).

All four modes share the same browser tools (`goto`, `click`, `fill`, `tree`,
`markdown`, `search`, ...). The same set is exposed over MCP via `lightpanda
mcp`, so an agent script and an MCP client see the same surface — that is
also the way to drive Lightpanda from an external LLM agent (Claude Code,
etc.) without giving Lightpanda its own API key.

## Quick start

```console
# Interactive REPL — auto-detects an API key from your environment
./lightpanda agent

# Force a specific provider
./lightpanda agent --provider anthropic

# Basic REPL (no LLM, PandaScript only)
./lightpanda agent --no-llm

# Replay a recorded script
./lightpanda agent session.lp

# Replay then continue interactively, appending new commands to the file
./lightpanda agent -i session.lp

# One-shot: ask a question, capture the answer on stdout
./lightpanda agent --task "what is on the front page of hn?"
```

## Providers and API keys

| Provider    | Flag                   | API key env                          |
|-------------|------------------------|--------------------------------------|
| Anthropic   | `--provider anthropic` | `ANTHROPIC_API_KEY`                  |
| OpenAI      | `--provider openai`    | `OPENAI_API_KEY`                     |
| Gemini      | `--provider gemini`    | `GOOGLE_API_KEY` or `GEMINI_API_KEY` |
| Ollama      | `--provider ollama`    | none (local)                         |

Defaults: `--model` falls back to a sensible per-provider default; `--base-url`
overrides the API endpoint (Ollama defaults to `http://localhost:11434/v1`).

### Provider auto-detection

When `--provider` is omitted, lightpanda inspects the environment and picks one:

- **No keys set** → falls back to the basic REPL (PandaScript only). Natural
  language, `/login`, `/acceptCookies`, and `--self-heal` will reject. A
  one-line notice is printed so you know which mode you landed in.
- **Exactly one key set** → that provider is used. A one-line notice
  identifies the env var that won.
- **Multiple keys set, on a TTY** → a numbered prompt asks which to use.
- **Multiple keys set, non-interactive** → the agent fails fast and tells
  you to pass `--provider` explicitly. Ollama is never auto-detected
  (no env var to look at) — pass `--provider ollama` if you want it.

`--no-llm` is the explicit bypass: it forces the basic REPL even when an
API key is present or `--provider` is set. Use it to test PandaScript
without burning tokens, or to disable the LLM in a saved command without
editing the existing flags. `--no-llm` wins over `--provider`.

## PandaScript

PandaScript is a tiny, line-oriented DSL for browser actions. Each line is a
slash command (`/<tool> [args]`), a `#` comment, or blank. There is no other
syntax: anything that doesn't match those three forms is a parse error.

Slash commands accept any of:

- a single positional value, when the tool has exactly one required field —
  `/goto 'https://example.com'`, `/click selector='Login'`,
  `/extract '{"karma":"#karma"}'`;
- `key=value` pairs — values may be bare or quoted; strings with whitespace
  must be quoted (`/fill selector='#email' value='user@x.com'`);
- a raw `{json}` blob — handed straight to the tool (`/findElement
  {"role":"button"}`).

Quoting is content-aware: `'…'`, `"…"`, and triple-quoted `'''…'''` /
`"""…"""` for values that mix both quote styles or span multiple lines.
Recorded scripts round-trip through the parser without escapes.

Two slash commands have no underlying tool — they trigger an LLM turn that
the agent translates into actual tool calls:

| Command          | Notes                                                |
|------------------|------------------------------------------------------|
| `/login`         | LLM-driven: fills credentials from `$LP_*` env vars. |
| `/acceptCookies` | LLM-driven: dismiss the consent banner.              |

Both require an LLM. `--no-llm` rejects them.

In the REPL (and only the REPL), a line that isn't a slash command and
doesn't start with `#` is sent to the LLM as a natural-language prompt. In
`.lp` scripts and through MCP `script_step`, the same input is a parse
error. To leave the REPL, use the `/quit` meta command.

### Example script

```pandascript
# Log into the demo and grab the dashboard title and visible cards.
# Site-scoped vars (LP_<SITE>_<FIELD>) avoid collisions when you have
# credentials for several sites; the unprefixed form is the fallback.
/goto 'https://demo-browser.lightpanda.io/'
/acceptCookies
/fill selector='#email' value='$LP_DEMO_USERNAME'
/fill selector='#password' value='$LP_DEMO_PASSWORD'
/click selector='button[type="submit"]'
/waitForSelector '.dashboard'
/extract '{"title": ".dashboard h1", "cards": [".dashboard .card .name"]}'
```

`/extract` takes a JSON schema object — each value tells the extractor
what to lift off the page, and the whole result is printed to stdout
as a single JSON object. Supported value forms:

- `"<sel>"` — `textContent.trim()` of the first match (string or `null`).
- `""` — the matched element's own text (only inside a `fields` block).
- `["<sel>"]` — text of every match (string array).
- `{"selector": "<sel>", "attr": "<name>"}` — attribute of the first match.
- `[{"selector": "<sel>", "fields": {…}}]` — array of records, each
  `fields` value resolved relative to the matched element.

Use `/extract '''…'''` (or `"""…"""`) to spread a schema across multiple
lines. The schema is parsed in Zig before the page-side walker runs,
so a malformed schema fails with `Error: invalid /extract schema JSON`
rather than a V8 stack trace. See [agent-tutorial.md](agent-tutorial.md)
section 3 for a worked example against Hacker News.

### Recording

Interactive sessions can write back to a `.lp` file:

```console
./lightpanda agent -i session.lp
```

State-mutating commands (`/goto`, `/click`, `/fill`, `/scroll`, `/hover`,
`/selectOption`, `/setChecked`, `/waitForSelector`, `/press`, `/eval`,
`/extract`) are appended; read-only commands (`/tree`, `/markdown`,
`/links`, `/findElement`, …) and the natural-language turns that produced
them are not. Natural-language turns are recorded as `# <prompt>` comments
above the resulting slash commands so the script stays readable.

### Replay and self-healing

`./lightpanda agent script.lp` replays without making any LLM call.

With `--self-heal --provider <p>`, a failed command (typically a stale
selector after the page changed) triggers a short LLM turn that inspects the
current page and emits a replacement command. The healed command runs, and
the original script line is rewritten in place so the next replay succeeds
deterministically.

Self-heal is constrained: at most one replacement per failure, capped LLM
budget, no navigation away from the current page. It is meant to recover
from selector drift, not to redesign the script.

## REPL features

- **Tab completion** (case-insensitive): cycles through `/<tool>` and meta
  slash commands. The dim grey suffix shown after the cursor is the first
  match.
- **Persistent history**: stored in `.lp-history` in the working directory.
- **Meta slash commands**: `/help` lists tools (`/help <tool>` prints the
  JSON schema), `/quit` exits the REPL, `/verbosity <low|medium|high>` tunes
  the log level. These are REPL-only and never recorded.
  ```
  > /goto https://example.com
  > /findElement role=button name=Submit
  > /eval {"script": "document.title"}
  > /quit
  ```
- **Stdout vs stderr**: the final assistant answer and data-producing slash
  commands (`/extract`, `/eval`, `/markdown`, `/tree`, …) write to stdout.
  Tool calls, progress, and errors go to stderr, so `lightpanda agent --task
  ... > out.txt` captures a clean answer.

## One-shot mode (`--task`)

```console
./lightpanda agent --provider gemini \
  --task "what is the top story on news.ycombinator.com?"
```

`--task` runs a single user turn, prints the final answer on stdout, and
exits. Combine with `-a <path>` / `--attach <path>` (repeatable) to feed local
files to providers that accept attachments. Text files are inlined into
the prompt (max 512 KiB each); binary files (`image/*`, `audio/*`, `pdf`)
are base64-encoded inline (max 20 MiB each). Unsupported MIME types
error out before any browser work runs.

## Driving Lightpanda from an external LLM agent

When the calling agent already has its own LLM (e.g. Claude Code), use
`lightpanda mcp` rather than `lightpanda agent`. The MCP server exposes
the same browser tools (`goto`, `click`, `fill`, ...) listed below, so
the external agent does the planning while Lightpanda only drives the
browser. No `--provider` or API key is required on the Lightpanda side.

```json
{
  "mcpServers": {
    "lightpanda": {
      "command": "/path/to/lightpanda",
      "args": ["mcp"]
    }
  }
}
```

For sub-task delegation in the other direction — calling Lightpanda's
own LLM-driven agent in a one-shot fashion — use `--task` on stdin
instead.

### Recording PandaScript over MCP

`lightpanda mcp` exposes three recording tools so an external agent can
capture a session as a `.lp` script for later deterministic replay:

| Tool             | Args                  | Effect                                                                                          |
|------------------|-----------------------|-------------------------------------------------------------------------------------------------|
| `record_start`   | `{ path: string }`    | Begin appending state-mutating tool calls to `path` (relative, no `..`). Errors if already on. |
| `record_stop`    | `{}`                  | Close the recording and return `{path, line_count}`. Errors if no recording is active.          |
| `record_comment` | `{ text: string }`    | Write `# <text>` to the active recording — useful as a breadcrumb above LLM-driven steps.       |

While recording is active, every `goto` / `click` / `fill` / `scroll` /
`hover` / `selectOption` / `setChecked` / `waitForSelector` / `eval`
that succeeds is appended verbatim. Query-only tools (`tree`,
`markdown`, `findElement`, `consoleLogs`, …) are not recorded. The
resulting file replays without an LLM via `./lightpanda agent
session.lp`.

### Replay + self-heal over MCP

Self-heal is a two-tool roundtrip: lightpanda runs steps and reports
structured failures, the calling agent synthesizes a replacement, and
lightpanda atomically rewrites the script.

| Tool          | Args                                                     | Effect                                                                                                                                              |
|---------------|----------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `script_step` | `{ line: string }`                                       | Parse one PandaScript line and run it on the current session. Comments and blank lines are no-ops. Returns `isError: true` with a structured message on failure. |
| `script_heal` | `{ path: string, replacements: [{original_line, replacement_lines}] }` | Atomically rewrite the script in place. A `<path>.bak` of the original is written first; each `original_line` must match verbatim. The first replacement gets a `# [Auto-healed] Original: …` header. |

Typical loop on the caller side: read the script, walk lines, call
`script_step` per line, on failure ask the caller's LLM for a
replacement, call `script_heal` with the patch, then continue. Lines
executed via `script_step` are intentionally NOT auto-recorded — replay
shouldn't double-record.

`/login`, `/acceptCookies`, and anything that isn't a slash command are
rejected by `script_step`: those require an LLM and belong to the calling
agent.

## Browser tools

The agent and MCP server share the tool set defined in `src/browser/tools.zig`.
Highlights:

- `goto`, `search` (Google with DuckDuckGo fallback on captcha)
- `tree`, `markdown`, `links`, `interactiveElements`, `structuredData`,
  `detectForms`, `nodeDetails`, `findElement`
- `click`, `fill`, `hover`, `press`, `scroll`, `selectOption`, `setChecked`,
  `waitForSelector`
- `eval`, `consoleLogs`, `getUrl`, `getCookies`, `getEnv`

Selectors prefer CSS over `backendNodeId` for the click-family tools, since
node IDs are invalidated by any DOM mutation. The system prompt enforces this
for the LLM.

## Security notes

- The agent treats page content as untrusted data, not instructions. URLs
  surfaced by a page are not followed unless they match the user's task.
- `$LP_*` environment variable references in `/fill` values are resolved
  at execution time inside the subprocess, so credentials never enter the
  LLM context. Conventional naming for site-scoped values is
  `LP_<SITE>_<FIELD>` (e.g. `LP_HN_USERNAME`, `LP_GH_TOKEN`); the
  unprefixed `LP_USERNAME` / `LP_PASSWORD` form is the generic fallback.
- The `getEnv` tool only reads variables whose name starts with `LP_`.
  Everything else (provider API keys, system env, third-party secrets)
  reports "not set" so the model can't probe for it. The user controls
  what lives under `LP_*`. Note that `getEnv` returns the *value* to the
  model — fine for non-secret config like base URLs, but never call it
  on credentials (use `$LP_*` placeholders in fill values instead).
- `--obey-robots`, `--http-proxy`, `--user-agent`, and the rest of the
  browser-level CLI flags apply to `agent` the same way they apply to
  `serve`, `fetch`, and `mcp`.
- REPL prompts are persisted to `.lp-history` in the current working
  directory in plaintext (no encryption). Anything you type at the prompt
  — including natural-language context that accompanies a `/login` —
  lands in that file. Delete it or move out of sensitive directories if
  you don't want it retained.
- `record_start` and `script_heal` reject empty, absolute, and `..`
  paths, but do **not** follow-up on symlinks. On a shared filesystem,
  a pre-existing symlink at the recording target would be written
  through to whatever it points at. Prefer a fresh directory you own
  when recording in untrusted environments.
