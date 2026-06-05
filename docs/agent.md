# Agent mode

`lightpanda agent` turns Lightpanda's headless engine into a browsing agent you
can talk to in plain English, script deterministically, or drive from your own
LLM. There's no rendering and no images — it reasons over pages as text, which
makes browsing fast and cheap to automate.

**New here?** The [tutorial](agent-tutorial.md) walks you from a fresh build to a
recorded, replayable Hacker News scraper in a few minutes. This page is the
reference: every flag, slash command, and browser tool. For the JavaScript
script format, see [agent-script.md](agent-script.md).

`lightpanda agent` can act as:

- an **LLM agent** that drives the browser with tool calls (`--provider`),
- a **scripted runner** that runs a recorded `.js` script deterministically,
- a **basic REPL** for hand-driven slash commands with no LLM at all,
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

# Basic REPL (no LLM, slash commands only)
./lightpanda agent --no-llm

# Run a saved script, then exit
./lightpanda agent session.js

# One-shot: ask a question, capture the answer on stdout
./lightpanda agent --task "what is on the front page of hn?"

# See which models the resolved provider offers
./lightpanda agent --list-models
```

## Providers and API keys

| Provider    | Flag                   | API key env                          |
|-------------|------------------------|--------------------------------------|
| Anthropic   | `--provider anthropic` | `ANTHROPIC_API_KEY`                  |
| OpenAI      | `--provider openai`    | `OPENAI_API_KEY`                     |
| Gemini      | `--provider gemini`    | `GOOGLE_API_KEY` or `GEMINI_API_KEY` |
| Ollama      | `--provider ollama`    | none (local)                         |

Defaults: `--model` falls back to a sensible per-provider default; in the REPL,
`/provider <name>` and `/model <name>` change the current selection (Tab
completes the candidates). `--base-url` overrides the API endpoint (Ollama
defaults to `http://localhost:11434/v1`). Run `--list-models` to see exactly
what the resolved provider offers, `--system-prompt` to swap in your own
system prompt, and `--verbosity <low|medium|high>` to tune how much progress
detail goes to stderr (`--task` defaults to `low`, or `high` when stderr is
piped/redirected so harnesses capture the full `[tool/result]` trace).

`--model` is validated against the provider's catalog up front: an unknown name
fails fast with a pointer to `--list-models` rather than erroring mid-task. For
Ollama, the default model is checked against what's actually pulled — if it's
missing, the agent falls back to the first installed model (an explicit
`--model` that isn't installed errors instead, with an `ollama pull` hint).

### Provider auto-detection

When `--provider` is omitted, lightpanda picks one in this order. The REPL shows
the resolved provider and model in its status bar; the multi-key picker and any
fallback notices (e.g. an Ollama default that isn't installed) print to stderr:

1. **Remembered** → the provider/model you last selected with `/provider` or
   `/model`, persisted per-directory in `.lp-agent.zon`, as long as its key is
   still set.
2. **Auto-detected** → otherwise the first key found in priority order
   (`ANTHROPIC_API_KEY` → `GOOGLE_API_KEY`/`GEMINI_API_KEY` → `OPENAI_API_KEY`).
   If several keys are set and you're in an interactive REPL, the agent prompts
   you to choose; non-interactive runs (`--task`, pipes, `--list-models`) take
   the first. Switch any time with `/provider`, or override with `--provider`.
3. **Local Ollama** → if no cloud key is set, the agent probes a local Ollama
   server (`http://localhost:11434/v1`, or `--base-url`) and uses it when it
   answers with at least one pulled model.
4. **No provider at all** → falls back to the basic REPL (slash commands only).
   Natural language and the LLM-driven commands (`/login`, `/logout`,
   `/acceptCookies`) will reject.

`--no-llm` is the explicit bypass: it forces the basic REPL even when an
API key is present or `--provider` is set. Use it to test slash commands
without burning tokens, or to disable the LLM in a saved command without
editing the existing flags. `--no-llm` wins over `--provider`.

## REPL Slash Commands

The REPL uses a tiny slash-command language for browser actions. Each command is
`/<tool> [args]`, a `#` comment, or blank. There is no other syntax in basic
REPL mode: anything that doesn't match those three forms is a parse error.

Slash commands accept any of:

- a single positional value, when the tool has exactly one required field —
  `/goto 'https://example.com'`, `/extract '{"karma":"#karma"}'`;
- `key=value` pairs — values may be bare or quoted; strings with whitespace
  must be quoted (`/fill selector='#email' value='user@x.com'`);
- a raw `{json}` blob — handed straight to the tool (`/findElement
  {"role":"button"}`).

Tools whose selector is optional (e.g. `/click`, `/hover`, `/findElement`)
have zero required fields, so they don't take a positional and must be
written as `key=value`: `/click selector='a.login'`, not `/click 'a.login'`.

Quoting is content-aware: `'…'`, `"…"`, and triple-quoted `'''…'''` /
`"""…"""` for values that mix both quote styles or span multiple lines.
Recorded JavaScript scripts use the equivalent function-call form instead of
slash lines.

Two slash commands have no underlying tool — they trigger an LLM turn that
the agent translates into actual tool calls:

| Command          | Notes                                                |
|------------------|------------------------------------------------------|
| `/login`         | LLM-driven: fills credentials from `$LP_*` env vars. |
| `/logout`        | LLM-driven: find the logout control and sign out.    |
| `/acceptCookies` | LLM-driven: dismiss the consent banner.              |

All three require an LLM. `--no-llm` rejects them.

In the REPL (and only the REPL), a line that isn't a slash command and
doesn't start with `#` is sent to the LLM as a natural-language prompt. To
leave the REPL, use the `/quit` meta command.

### Example script

```console
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
- `["<sel>"]` — text of every match (string array). Sugar for
  `[{"selector": "<sel>"}]`.
- `{"selector": "<sel>", "attr": "<name>"}` — attribute of the first match.
- `[{"selector": "<sel>", "fields": {…}}]` — array of records, each
  `fields` value resolved relative to the matched element.
- Add `"limit": N` inside any array's object spec to cap matches at N
  (works for text, attribute, and `fields` shapes — e.g.
  `[{"selector": ".story .title", "limit": 5}]` for top 5 titles).

Use `/extract '''…'''` (or `"""…"""`) to spread a schema across multiple
lines. The schema is parsed in Zig before the page-side walker runs, so a
malformed schema is rejected up front with a plain `Error: InvalidParams`
rather than a V8 stack trace. See [agent-tutorial.md](agent-tutorial.md)
section 3 for a worked example against Hacker News.

### Cross-call state with `lp.*`

`/extract` and `/evaluate` each return one value per call, but real scrapes
often need to carry data forward — capture a list on one page, then walk
it across navigations. Two primitives keep that simple.

**`save=<name>`** on `/extract` or `/evaluate` stashes the result in a
Session-scoped store keyed by `<name>` instead of dumping it to stdout.
The stored value is then exposed to every subsequent `/evaluate` as
`globalThis.lp.<name>`:

```console
/goto 'https://news.ycombinator.com/'

/extract save=front '''
{
  "stories": [{
    "selector": "tr.athing",
    "limit": 5,
    "fields": {
      "id":    {"attr": "id"},
      "title": ".titleline > a"
    }
  }]
}
'''

/evaluate '''
console.log(lp.front.stories[0].title);
'''
```

`save=`d commands print nothing on success so scripts pipe cleanly.

**Auto-sync.** Any mutation of `lp.*` inside an `/evaluate` is persisted at
the end of the call. Adding a key (`lp.x = …`), updating a nested value
(`lp.front.stories[0].comments = […]`), or removing a key
(`delete lp.x`) all propagate to the store. The next `/evaluate` sees the
update — even after a navigation, because the store lives Session-side,
not on the page.

**List → detail.** A common scrape captures a list, then visits each row
for more data. Capture the list with `/extract save=<name>`, then loop in
`/evaluate`: read `lp.<name>`, `goto` each row's URL, and extract the
detail — `/evaluate`'s top-level `await` and full JS make the round-trip
explicit.

**Async evaluate.** When a scrape needs logic `/extract` can't express, `/evaluate`
is the escape hatch: top-level `await` works directly — the body runs as
an async function, so use `return` to produce a value. `runEval` pumps
the event loop until it settles, then surfaces the resolved value (or the
rejection as an error). A body with no explicit `return` resolves to
`undefined`, which evaluate treats as silent. Returned objects and arrays
are serialized to JSON automatically, so no `JSON.stringify` is needed.

The store is **script-run scoped**: it's bound to the Session that runs
the script, and goes away when that Session does. There is no
cross-session persistence; if you need that, use `localStorage` (which
is origin-scoped and persists across navigations within a session).

### Saving and loading

From the REPL, `/save [file.js]` writes the session back to a `.js` file
and `/load <path>` runs a script from disk against the current session.

`/save` works one of two ways. **With `--no-llm`** it transcribes the session
deterministically: state-mutating commands (`/goto`, `/click`, `/fill`,
`/scroll`, `/hover`, `/selectOption`, `/setChecked`, `/waitForSelector`,
`/waitForScript`, `/press`, `/evaluate`, `/extract`) become JavaScript calls,
read-only commands (`/tree`, `/markdown`, `/links`, `/findElement`, …) are
dropped, and each natural-language prompt that produced recorded actions is
written as a `// <prompt>` comment above those calls so the script stays
readable. **With an LLM** it instead synthesizes an idiomatic script from the
whole session — the synthesis prompt asks for JavaScript only ("no
commentary"), so the result generally has no such comments: the model folds
intent into the code and drops dead-ends.

### JavaScript Script Running

`./lightpanda agent script.js` runs without making any LLM call. Agent scripts
are plain synchronous JavaScript plus the installed Lightpanda primitives:

```js
goto("https://example.com");
click({ selector: "a.login" });
evaluate("document.title");
```

The script runs in an agent-only V8 context. It has no `window`, `document`, or
DOM APIs. Browser interaction happens only through the installed primitives
(`goto`, `click`, `fill`, `evaluate`, `extract`, and the other recorded browser
actions). The primitives are **synchronous and blocking** — each returns its
result directly, so write `const data = extract(…)`, not `await extract(…)`.
There is no `async`/`await`/Promise contract around them. (`evaluate(...)` can
run async JS *inside* the page, but the `evaluate(...)` call itself still returns
synchronously.) It is not Node.js either: there is no `require`, `process`, `fs`,
npm package loading, or Node standard library. The `evaluate(...)` primitive
executes its string in the current page context; page scripts cannot see agent
variables or agent primitives.

Tool errors throw JavaScript exceptions and stop execution.
See [agent-script.md](agent-script.md) for the full script format reference.

## REPL features

- **Status bar**: a line under the prompt shows the active model and quick
  hints (`! JS`, `Tab completes`, `/help`); in `--no-llm` it reads `basic REPL —
  slash commands only`. It drops the least-important segments first when the
  terminal is narrow.
- **JS mode** (`!`): type `!` on an empty prompt to toggle a scratchpad where the
  whole line runs as page-side JavaScript — the same context as `evaluate`, so
  `document` and `window` are in scope. Handy for poking at a page without
  wrapping every line in `/evaluate`. `$LP_*` refs are still resolved at
  execution, console output is echoed back, and `Esc` exits. JS-mode lines are
  not recorded.
- **Tab completion** (case-insensitive): cycles through `/<tool>` and meta
  slash commands. The dim grey suffix shown after the cursor is the first
  match.
- **Persistent history**: stored in `.lp-history` in the working directory.
- **Meta slash commands**: `/help` lists tools (`/help <tool>` prints the
  JSON schema), `/provider [name]` and `/model [name]` change the active
  provider/model — Tab after the space completes from detected providers and
  the provider's fetched model list, and bare `/provider`/`/model` print the
  current selection — `/save [file.js]` writes the session to a script and
  `/load <path>` runs one from disk (Tab completes file paths), `/quit` exits
  the REPL, `/verbosity <low|medium|high>` tunes the log level. These are
  REPL-only and never recorded.
  ```
  > /goto https://example.com
  > /findElement role=button name=Submit
  > /evaluate {"script": "document.title"}
  > /quit
  ```
- **Stdout vs stderr**: the final assistant answer and data-producing slash
  commands (`/extract`, `/evaluate`, `/markdown`, `/tree`, …) write to stdout.
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

Tool names are camelCase and case-sensitive — there are no aliases. MCP
clients must call the canonical tags (`goto`, `evaluate`, `tree`, `save`, …).

For sub-task delegation in the other direction — calling Lightpanda's
own LLM-driven agent in a one-shot fashion — use `--task` on stdin
instead.

### Saving a script over MCP

`lightpanda mcp` exposes a `save` tool so an external agent can persist
the session as a `.js` script for later deterministic replay. Unlike the
standalone agent's `/save`, the MCP server has no LLM of its own — the
calling client holds the conversation, so it synthesizes the script and
passes it in:

| Tool   | Args                               | Effect                                                                                                              |
|--------|------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `save` | `{ path: string, script: string }` | Write `script` to `path` (relative, no `..`; created or overwritten) and return the absolute location and line count. |

The tool's description carries the same synthesis guidance the agent's
`/save` gives its LLM: prefer the builtins you called as tools (`goto`,
`click`, `fill`, `extract`, …) as JavaScript calls, drop dead-ends, and
keep `$LP_*` placeholders. Any literal `LP_*` value is scrubbed back to
its placeholder before the file is written. The result runs without an
LLM via `./lightpanda agent session.js`.

## Browser tools

The agent and MCP server share the tool set defined in `src/browser/tools.zig`.
Highlights:

- `goto`, `search` (Tavily when `TAVILY_API_KEY` is set, DuckDuckGo otherwise)
- `tree`, `markdown`, `html`, `links`, `interactiveElements`, `structuredData`,
  `detectForms`, `nodeDetails`, `findElement`
- `click`, `fill`, `hover`, `press`, `scroll`, `selectOption`, `setChecked`,
  `waitForSelector`, `waitForScript`
- `extract` (the schema-driven data tool), `evaluate`, `consoleLogs`, `getUrl`,
  `getCookies`, `getEnv`

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
- `save` rejects empty, absolute, and `..` paths, but does **not**
  follow up on symlinks. On a shared filesystem, a pre-existing symlink
  at the target would be written through to whatever it points at.
  Prefer a fresh directory you own when saving in untrusted environments.
