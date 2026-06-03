# Agent mode

> Looking for a step-by-step walkthrough instead of a reference?
> See [agent-tutorial.md](agent-tutorial.md) — it builds one end-to-end
> Hacker News scenario covering the REPL, recording, replay, and the MCP
> roundtrip.
>
> Looking for the JavaScript script format?
> See [agent-script.md](agent-script.md) for the runtime contract and
> primitive API.

`lightpanda agent` runs a browsing agent backed by Lightpanda's headless engine.
It can act as:

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

# Run a recorded script
./lightpanda agent session.js

# Replay then continue interactively, appending new commands to the file
./lightpanda agent -i session.js

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

Defaults: `--model` falls back to a sensible per-provider default; in the REPL,
`/provider <name>` and `/model <name>` change the current selection (Tab
completes the candidates). `--base-url` overrides the API endpoint (Ollama
defaults to `http://localhost:11434/v1`).

### Provider auto-detection

When `--provider` is omitted, lightpanda picks one in this order, printing a
one-line notice (on stderr) of what it chose:

1. **Remembered** → the provider/model you last selected with `/provider` or
   `/model`, persisted per-directory in `.lp-agent.zon`, as long as its key is
   still set.
2. **Auto-detected** → otherwise the first key found in priority order
   (`ANTHROPIC_API_KEY` → `GOOGLE_API_KEY`/`GEMINI_API_KEY` → `OPENAI_API_KEY`).
   Switch any time with `/provider` in the REPL, or override with `--provider`.
3. **No keys set** → falls back to the basic REPL (slash commands only).
   Natural language, `/login`, and `/acceptCookies` will reject.

Ollama is never auto-detected (no env var to look at) — pass `--provider
ollama`, or select it once with `/provider ollama` and it'll be remembered.

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
| `/acceptCookies` | LLM-driven: dismiss the consent banner.              |

Both require an LLM. `--no-llm` rejects them.

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
- Add `"follow": <url>` to a spec to fetch a per-row sub-page and resolve
  the spec's `selector`/`limit`/`fields` against *that* document instead
  of the current element — a declarative "scrape a list, then visit each
  row." `<url>` is either a string template whose `{name}` placeholders
  fill from sibling fields on the same row (`"/item?id={id}"`), or an
  element-spec read off the row (`{"selector": "a.comments", "attr":
  "href"}`). Fetches resolve relative to the current page and run
  sequentially; a failed fetch yields `null` (or `[]`) for that field.
  See the worked example below.

Use `/extract '''…'''` (or `"""…"""`) to spread a schema across multiple
lines. The schema is parsed in Zig before the page-side walker runs,
so a malformed schema fails with `Error: invalid /extract schema JSON`
rather than a V8 stack trace. See [agent-tutorial.md](agent-tutorial.md)
section 3 for a worked example against Hacker News.

### Cross-call state with `lp.*`

`/extract` and `/eval` each return one value per call, but real scrapes
often need to carry data forward — capture a list on one page, then walk
it across navigations. Two primitives keep that simple.

**`save=<name>`** on `/extract` or `/eval` stashes the result in a
Session-scoped store keyed by `<name>` instead of dumping it to stdout.
The stored value is then exposed to every subsequent `/eval` as
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

/eval '''
console.log(lp.front.stories[0].title);
'''
```

`save=`d commands print nothing on success so scripts pipe cleanly.

**Auto-sync.** Any mutation of `lp.*` inside an `/eval` is persisted at
the end of the call. Adding a key (`lp.x = …`), updating a nested value
(`lp.front.stories[0].comments = […]`), or removing a key
(`delete lp.x`) all propagate to the store. The next `/eval` sees the
update — even after a navigation, because the store lives Session-side,
not on the page.

**List → detail with `follow`.** A common scrape captures a list, then
visits each row for more data. `/extract`'s `follow` does that in one
declarative call — no `lp.*` round-trip, no hand-written loop. The HN
front page plus the top comments of each story:

```console
/goto 'https://news.ycombinator.com/'

/extract '''
{
  "stories": [{
    "selector": "tr.athing",
    "limit": 5,
    "fields": {
      "id":    {"attr": "id"},
      "title": ".titleline > a",
      "comments": [{
        "follow": "/item?id={id}",
        "selector": "tr.athing.comtr:has(td.ind img[width=\"0\"]):has(.commtext)",
        "limit": 3,
        "fields": {"author": ".hnuser", "text": ".commtext"}
      }]
    }
  }]
}
'''
```

`{id}` fills from each story's `id` field; the walker fetches
`/item?id=<id>`, parses it, and resolves the inner `selector`/`fields`
against that page. The whole nested result prints to stdout as one JSON
object.

**Async eval.** When a scrape needs logic `follow` can't express, `/eval`
is the escape hatch: top-level `await` works directly — the body runs as
an async function, so use `return` to produce a value. `runEval` pumps
the event loop until it settles, then surfaces the resolved value (or the
rejection as an error). A body with no explicit `return` resolves to
`undefined`, which the eval treats as silent. Returned objects and arrays
are serialized to JSON automatically, so no `JSON.stringify` is needed.

The store is **script-run scoped**: it's bound to the Session that runs
the script, and goes away when that Session does. There is no
cross-session persistence; if you need that, use `localStorage` (which
is now origin-scoped and persists across navigations within a session).

### Recording

Interactive sessions can write back to a `.js` file:

```console
./lightpanda agent -i session.js
```

State-mutating commands (`/goto`, `/click`, `/fill`, `/scroll`, `/hover`,
`/selectOption`, `/setChecked`, `/waitForSelector`, `/press`, `/eval`,
`/extract`) are appended; read-only commands (`/tree`, `/markdown`,
`/links`, `/findElement`, …) and the natural-language turns that produced
them are not. Natural-language turns are recorded as `// <prompt>` comments
above the resulting JavaScript calls so the script stays readable.

### JavaScript Script Running

`./lightpanda agent script.js` runs without making any LLM call. Agent scripts
are plain synchronous JavaScript plus the installed Lightpanda primitives:

```js
goto("https://example.com");
click({ selector: "a.login" });
eval("document.title");
```

The script runs in an agent-only V8 context. It has no `window`, `document`, or
DOM APIs. Browser interaction happens only through the installed primitives
(`goto`, `click`, `fill`, `eval`, `extract`, and the other recorded browser
actions). It is not Node.js either: there is no `require`, `process`, `fs`, npm
package loading, or Node standard library. The `eval(...)` primitive executes
its string in the current page context; page scripts cannot see agent variables
or agent primitives.

Tool errors throw JavaScript exceptions and stop execution.
See [agent-script.md](agent-script.md) for the full script format reference.

## REPL features

- **Tab completion** (case-insensitive): cycles through `/<tool>` and meta
  slash commands. The dim grey suffix shown after the cursor is the first
  match.
- **Persistent history**: stored in `.lp-history` in the working directory.
- **Meta slash commands**: `/help` lists tools (`/help <tool>` prints the
  JSON schema), `/provider [name]` and `/model [name]` change the active
  provider/model — Tab after the space completes from detected providers and
  the provider's fetched model list, and bare `/provider`/`/model` print the
  current selection — `/quit` exits the REPL, `/verbosity <low|medium|high>`
  tunes the log level. These are REPL-only and never recorded.
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

Tool names are camelCase and case-sensitive — there are no aliases.
Earlier snake_case names (`navigate`, `evaluate`, `semantic_tree`, …)
have been removed; MCP clients must call the canonical tags (`goto`,
`eval`, `tree`, `save`, …).

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
- `save` rejects empty, absolute, and `..` paths, but does **not**
  follow up on symlinks. On a shared filesystem, a pre-existing symlink
  at the target would be written through to whatever it points at.
  Prefer a fresh directory you own when saving in untrusted environments.
