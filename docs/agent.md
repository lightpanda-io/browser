# Agent mode

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
  language, `LOGIN`, `ACCEPT_COOKIES`, and `--self-heal` will reject. A
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

PandaScript is a tiny, line-oriented DSL for browser actions. Each line is one
command. Comments start with `#`. Strings are quoted with `'`, `"`, or `'''…'''`
for values that mix both quote styles. Quoting rules are content-aware so that
recorded scripts round-trip through the parser.

| Command          | Form                                  | Notes                                                |
|------------------|---------------------------------------|------------------------------------------------------|
| `GOTO`           | `GOTO <url>`                          | Navigate. URL is unquoted.                           |
| `CLICK`          | `CLICK '<selector>'`                  | CSS selector.                                        |
| `TYPE`           | `TYPE '<selector>' '<value>'`         | Fills an input. `$LP_*` env refs auto-resolve.       |
| `WAIT`           | `WAIT '<selector>'`                   | Wait for selector to be present in the DOM.          |
| `SCROLL`         | `SCROLL [x] [y]`                      | Default `(0, 0)`.                                    |
| `HOVER`          | `HOVER '<selector>'`                  |                                                      |
| `SELECT`         | `SELECT '<selector>' '<value>'`       | `<select>` option by value.                          |
| `CHECK`          | `CHECK '<selector>' [true\|false]`    | Check / uncheck. Default `true`.                     |
| `EXTRACT`        | `EXTRACT '<selector>'`                | Returns text content.                                |
| `EVAL`           | `EVAL '<js>'` or `EVAL '''…'''`       | Triple-quote for multi-line JS.                      |
| `TREE`           | `TREE`                                | Print the semantic tree (not recorded).              |
| `MARKDOWN`       | `MARKDOWN`                            | Print page as markdown (not recorded).               |
| `LOGIN`          | `LOGIN`                               | LLM-driven: fill `$LP_USERNAME` / `$LP_PASSWORD`.    |
| `ACCEPT_COOKIES` | `ACCEPT_COOKIES`                      | LLM-driven: dismiss the consent banner.              |

In the REPL, anything that does not parse as a PandaScript command is sent to
the LLM as natural language. To leave the REPL, use the `/quit` slash command.

### Example script

```pandascript
# Log into the demo and grab the dashboard title.
GOTO https://demo-browser.lightpanda.io/
ACCEPT_COOKIES
TYPE '#email' '$LP_USERNAME'
TYPE '#password' '$LP_PASSWORD'
CLICK 'button[type="submit"]'
WAIT '.dashboard'
EXTRACT '.dashboard h1'
```

### Recording

Interactive sessions can write back to a `.lp` file:

```console
./lightpanda agent -i session.lp
```

State-mutating commands (`GOTO`, `CLICK`, `TYPE`, ...) are appended; read-only
commands (`TREE`, `MARKDOWN`) and the natural-language turns that produced
them are not. Natural-language turns are recorded as `# <prompt>` comments
above the resulting tool calls so the script stays readable.

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

- **Tab completion** (case-insensitive): cycles through PandaScript keywords
  and `/<tool>` slash commands. The dim grey suffix shown after the cursor is
  the first match.
- **Persistent history**: stored in `.lp-history` in the working directory.
- **Slash commands**: `/<tool> [args]` calls a browser tool directly without
  going through the LLM. Args accept either a single positional value (for
  tools with one required field), `key=value` pairs, or a raw `{json}` blob.
  Two meta commands round out the set: `/help` lists tools (`/help <tool>`
  prints the JSON schema), and `/quit` exits the REPL.
  ```
  > /goto https://example.com
  > /findElement role=button name=Submit
  > /eval {"script": "document.title"}
  > /quit
  ```
- **Stdout vs stderr**: the final assistant answer and data-producing commands
  (`EXTRACT`, `EVAL`, `MARKDOWN`, `TREE`) write to stdout. Tool calls,
  progress, and errors go to stderr, so `lightpanda agent --task ... > out.txt`
  captures a clean answer.

## One-shot mode (`--task`)

```console
./lightpanda agent --provider gemini \
  --task "what is the top story on news.ycombinator.com?"
```

`--task` runs a single user turn, prints the final answer on stdout, and
exits. Combine with `--task-attachment <path>` (repeatable) to feed local
files to providers that accept attachments.

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

`LOGIN`, `ACCEPT_COOKIES`, and natural-language steps are rejected by
`script_step`: those require an LLM and belong to the calling agent.

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
- `$LP_*` environment variable references in `TYPE` / `fill` values are
  resolved at execution time, so credentials never enter the LLM context.
- The `getEnv` tool only reads variables whose name starts with `LP_`.
  Everything else (provider API keys, system env, third-party secrets)
  reports "not set" so the model can't probe for it. The user controls
  what lives under `LP_*`.
- `--obey-robots`, `--http-proxy`, `--user-agent`, and the rest of the
  browser-level CLI flags apply to `agent` the same way they apply to
  `serve`, `fetch`, and `mcp`.
