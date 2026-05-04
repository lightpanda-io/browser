# Agent mode

`lightpanda agent` runs a browsing agent backed by Lightpanda's headless engine.
It can act as:

- an **LLM agent** that drives the browser with tool calls (`--provider`),
- a **scripted runner** that replays a `.lp` script deterministically,
- a **dumb REPL** for hand-driven PandaScript with no LLM at all,
- a **one-shot task runner** that prints a single answer to stdout (`--task`),
- an **MCP server** that exposes the agent itself as a single `task` tool
  for other agents to delegate to (`--mcp`).

All five modes share the same browser tools (`goto`, `click`, `fill`, `tree`,
`markdown`, `search`, ...). The same set is exposed over MCP via `lightpanda
mcp`, so an agent script and an MCP client see the same surface.

## Quick start

```console
# Interactive REPL with an LLM
./lightpanda agent --provider anthropic

# Dumb REPL (no API key, PandaScript only)
./lightpanda agent

# Replay a recorded script
./lightpanda agent session.lp

# Replay then continue interactively, appending new commands to the file
./lightpanda agent -i session.lp

# One-shot: ask a question, capture the answer on stdout
./lightpanda agent --provider gemini --task "what is on the front page of hn?"

# MCP server: expose a single `task` tool for other agents to delegate to
./lightpanda agent --mcp --provider anthropic
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

Without `--provider`, the REPL still works for PandaScript commands. Natural
language, `LOGIN`, `ACCEPT_COOKIES`, and `--self-heal` all require a provider.

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

## MCP server mode (`--mcp`)

`lightpanda agent --mcp --provider <p>` runs the agent as an MCP server
over stdio. It exposes a single tool, `task`, so a calling agent can
delegate a high-level browsing task and receive only the final answer
without the intermediate browser tool calls (tree dumps, clicks, scrolls)
filling its own context.

```console
./lightpanda agent --mcp --provider anthropic
```

MCP configuration:

```json
{
  "mcpServers": {
    "lightpanda-agent": {
      "command": "/path/to/lightpanda",
      "args": ["agent", "--mcp", "--provider", "anthropic"]
    }
  }
}
```

The `task` tool accepts:

| Field         | Type             | Notes                                                                  |
|---------------|------------------|------------------------------------------------------------------------|
| `task`        | string, required | Natural-language instruction for the agent.                            |
| `attachments` | string[]         | Optional local file paths (image / PDF / text) for providers that accept attachments. |
| `fresh`       | boolean          | If true, start the task from a fresh browser session (no cookies, no current page). |

Each call resets the agent's LLM conversation, so tasks are independent
from each other at the model level. The browser session, by contrast,
persists across calls by default — set `fresh: true` to reset it.

This mode is distinct from `lightpanda mcp`, which exposes the raw
browser tools (`goto`, `click`, `fill`, ...) and does not depend on an
LLM. Pick `lightpanda mcp` when the calling agent wants to drive the
browser itself, and `lightpanda agent --mcp` when it wants to hand off
the whole sub-task. `--mcp` cannot be combined with `--task`, `-i`, or a
script file.

Limitations: the JSON-RPC loop is single-threaded, so a long-running
task call blocks subsequent calls until it finishes. There is no
cancellation from the client side yet.

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
