# Agent mode

`lightpanda agent` lets you drive a headless browser by talking to it.

You tell it where to go and what to extract, in plain English or with slash
commands, and it controls a real browser to do the work. Think of it as a
robot you're directing to use the web, not a chatbot you're having a
conversation with.

Every session starts by navigating to a page, either by
saying so ("go to news.ycombinator.com") or by typing `/goto <url>`. There's
no window to look at; the browser runs headlessly and you see its output
(extracted data, the agent's answer) in your terminal.

## How to think about it

The agent stacks three layers:

1. **The browser.** Loads pages, runs JavaScript, tracks cookies, follows
   redirects. The same engine that powers `lightpanda serve` and
   `lightpanda fetch`.
2. **A set of tools.** Things the browser knows how to do: `goto`, `click`,
   `fill`, `extract`, `evaluate`, `search`, and more. Each is available as a
   slash command (`/goto`, `/click`, ...).
3. **An LLM.** Reads your plain-English request and decides which tools to
   call. Optional. The agent can also run without it.

You can talk to any of the three layers. Type `/goto example.com` and you
call the browser tool directly. Type "find me the cheapest flight from NYC
to Tokyo" and the LLM picks the tools to use. Save what worked to a `.js`
file and you can replay the whole flow later without ever calling the LLM
again.

## Quick start

Set an API key for your preferred provider:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

(Or `OPENAI_API_KEY` / `GOOGLE_API_KEY`. Without a key the agent runs in a
slash-commands-only mode without natural language.)

Launch the REPL:

```bash
./lightpanda agent
```

Tell it what you want:

```
❯ go to news.ycombinator.com and get me the top story title and points
```

The agent navigates, extracts, prints the answer. When you're happy with
the result, save it and replay it right away to check it holds up without
the LLM:

```
❯ /save hn-top-story.js
❯ /load hn-top-story.js
❯ /quit
```

You now have a `.js` file that does the same job deterministically:

```bash
./lightpanda agent hn-top-story.js
```

No LLM call, no API key needed at replay time, sub-second to run.

For a longer worked example (logging into a site, extracting structured
data across pages), see the [tutorial](agent-tutorial.md).

### Other ways to launch

```bash
# Force a specific provider, ignoring auto-detection
./lightpanda agent --provider anthropic

# REPL without an LLM: /goto, /extract, ... work; plain English doesn't
./lightpanda agent --no-llm

# One-shot: ask a question, print the answer to stdout, exit
./lightpanda agent --task "what is on the front page of hn?"
```

## Tips for getting useful saved scripts

The whole value of a saved script is that it keeps working after you walk away. 

- **Ask for the data you want, not the conversation about it.** "Get me the
  top 5 HN story titles and points, print them to stdout" beats "show me
  what's on Hacker News today." The synthesizer captures the data you asked
  for as an `extract()` call; vague prompts produce vague recordings.
- **Be specific about the page.** "Go to news.ycombinator.com" is much
  better than "find me what's on Hacker News".
- **Check the file with `cat your-script.js` before running it.** The
  script holds the *calls*, not the data, so look for an `extract(...)`
  whose schema covers the fields you asked for. If there isn't one, the
  recording missed something — try rewording your prompt.
- **When the page changes and a saved script breaks**, re-run with the LLM,
  get an updated answer, save again. You only pay the LLM when something
  genuinely changed.

## Providers and API keys

The agent needs an LLM to interpret natural language. Set the relevant API
key as an environment variable, or pass `--provider` explicitly.

| Provider  | Flag                   | API key env                          |
|-----------|------------------------|--------------------------------------|
| Anthropic | `--provider anthropic` | `ANTHROPIC_API_KEY`                  |
| OpenAI    | `--provider openai`    | `OPENAI_API_KEY`                     |
| Gemini    | `--provider gemini`    | `GOOGLE_API_KEY` or `GEMINI_API_KEY` |
| Ollama    | `--provider ollama`    | none (local)                         |

`--model` falls back to a sensible per-provider default. `--base-url`
overrides the API endpoint (Ollama defaults to `http://localhost:11434/v1`).
`--list-models` prints what the resolved provider offers and exits.
`--system-prompt` swaps in your own system prompt. `--verbosity
<low|medium|high>` tunes how much progress detail goes to stderr (`--task`
defaults to `low`, escalating to `high` when stderr is piped or redirected
so harnesses capture the full `[tool/result]` trace).

### How a provider gets picked

Without `--provider`, the agent picks one in this order:

1. **Remembered** - whatever you last selected with `/provider` or `/model`,
   persisted per-directory in `.lp-agent.zon`, as long as its key is still
   set.
2. **Auto-detected** - the first key found in priority order
   (`ANTHROPIC_API_KEY` → `GOOGLE_API_KEY`/`GEMINI_API_KEY` →
   `OPENAI_API_KEY`). With several keys on a TTY, you'll be prompted to
   pick.
3. **Local Ollama** - if no cloud key is set, the agent probes
   `http://localhost:11434/v1` and uses it if there's at least one model
   pulled.
4. **No provider at all** - falls back to the basic REPL (slash commands
   only). Natural language and LLM-driven commands (`/login`, `/logout`,
   `/acceptCookies`) will reject.

`--no-llm` is the explicit override. It forces the basic REPL even when an
API key is present. Useful for testing slash commands without burning
tokens.

### Reasoning effort

`--effort <none|minimal|low|medium|high|xhigh>` sets the per-turn reasoning
budget for thinking models. It maps to each provider's native
reasoning-effort knob and is ignored by non-thinking models. The REPL
defaults to `low` so turns stay snappy. `--task` defaults to `medium`
where answer quality matters more than per-turn latency. Higher
effort can mean fewer tool calls per task (the model plans better), so it's
a real tradeoff rather than a pure slowdown. Change it live in the REPL
with `/effort`; selection persists in `.lp-agent.zon`. Script replay makes
no LLM calls, so effort doesn't apply there.

The default depends on how you launched, which is easy to miss:
 
| Context        | Default effort | Why                                  |
|----------------|----------------|--------------------------------------|
| REPL           | `low`          | Keeps turns snappy                   |
| `--task`       | `medium`       | Answer quality matters more          |

## Slash commands

The REPL uses a small slash-command language for browser actions. Each line
you type at the prompt is either a slash command, a `#` comment, a blank
line, or (when an LLM is configured) a natural-language prompt.

Slash commands accept:

- A single positional value, when the tool has exactly one required field.
  `/goto 'https://example.com'`. The value can itself be quoted JSON when
  that's what the field takes: `/extract '{"karma":"#karma"}'` passes the
  string to extract's one required field, `schema`.
- `key=value` pairs. Values may be bare or quoted; strings with whitespace
  must be quoted. `/fill selector='#email' value='user@x.com'`. A positional
  and `key=value` pairs can be mixed, but the positional must come first:
  `/extract '{"karma":"#karma"}' save=me`.
- A raw `{json}` blob, handed straight to the tool.
  `/findElement {"role":"button"}`.

Tools whose selector is optional (`/click`, `/hover`, `/findElement`) take
no positional and must use `key=value` form: `/click selector='a.login'`.
`/help <tool>` prints any tool's JSON schema — required fields, optional
fields, and types.

Quoting is content-aware: `'…'`, `"…"`, and triple-quoted `'''…'''` /
`"""…"""` for values that mix quote styles or span multiple lines. Paste a
multi-line command and the REPL keeps the whole paste as one input; typed
line by line, Enter submits at each newline.

### LLM-driven helpers

Three slash commands trigger an LLM turn rather than a direct tool call:

| Command          | What it does                                          |
|------------------|-------------------------------------------------------|
| `/login`         | Fills credentials from `$LP_*` env vars.              |
| `/logout`        | Finds the logout control and signs out.               |
| `/acceptCookies` | Dismisses the consent banner.                         |

All three require an LLM. `--no-llm` rejects them.

### Meta commands

These don't drive the browser, they control the REPL itself:

| Command                  | What it does                                       |
|--------------------------|----------------------------------------------------|
| `/help`                  | Lists tools. `/help <tool>` prints the JSON schema.|
| `/provider [name]`       | Lists or switches provider.                        |
| `/model [name]`          | Lists or switches model for the active provider.   |
| `/effort <level>`        | Sets reasoning budget. Saved to `.lp-agent.zon`.   |
| `/verbosity <level>`     | Tunes the log level. Levels: low, medium, high.    |
| `/usage`                 | Prints cumulative token usage and cache hit rate.  |
| `/save [file] [prompt]`  | Writes the session to a script. `.js` is appended to the name if missing; trailing words guide the synthesizer.|
| `/load <path>`           | Runs a script from disk against the current session.|
| `/clear`                 | Forgets the conversation (history, usage, recorded actions, node IDs); keeps the page and cookies.|
| `/reset`                 | Full reset: everything `/clear` does, plus a fresh browser session, dropping the page, cookies, and storage.|
| `/quit`                  | Exits the REPL.                                    |

Meta commands are never recorded.

Use `/clear` when you want to test a new prompt against the current
page without losing your login or cookies. Use `/reset` when you need
a completely clean browser (no cookies, no current page, no storage).

## REPL features

- **Ghost hints.** There's no separate status line; guidance renders as dim
  ghost text after the cursor and disappears as you type over it. It
  previews the rest of the first matching command name, the argument shape
  of the tool you're typing (`/evaluate ` shows
  `<script> [url=…] [timeout=…] [save=…]`), and contextual nudges like
  "press Ctrl-D again to exit".
- **JS mode (`!`).** Type `!` on an empty prompt to toggle a scratchpad
  where the whole line runs as page-side JavaScript, same context as
  `/evaluate` so `document` and `window` are in scope. The prompt switches
  to `!` with a "JS mode - esc to exit" ghost hint. Handy for poking at
  a page without wrapping every line in `/evaluate`:

  ```
  ❯ !
  ! document.title
  "Hacker News"
  ! document.querySelectorAll('tr.athing').length
  30
  ```

  `$LP_*` refs are still resolved at execution, console output is echoed
  back, and `Esc` exits. JS-mode lines are not recorded.
- **Tab completion** (case-insensitive). Cycles through `/<tool>` and meta
  slash commands. The dim grey suffix shown after the cursor is the first
  match.
- **Persistent history.** Stored in `.lp-history` in the working directory.
- **Stdout vs stderr.** The final assistant answer and data-producing slash
  commands (`/extract`, `/evaluate`, `/markdown`, `/tree`, ...) write to
  stdout. Tool calls, progress, and errors go to stderr. So
  `lightpanda agent --task ... > out.txt` captures a clean answer.

## Extracting data 

`/extract` takes a JSON schema where each value tells the extractor what to
lift off the page. The result is printed to stdout as a single JSON object.

```console
# The demo shop renders its product data with an XHR after the initial
# HTML, so wait for it to land before extracting.
/goto 'https://demo-browser.lightpanda.io/campfire-commerce/'
/waitForSelector '#product-features li'
/extract '{"name": "#product-name", "price": "#product-price", "related": [{"selector": "#product-related div", "fields": {"name": "h4", "price": "p"}}]}'
```

```json
{
  "name": "Outdoor Odyssey Nomad Backpack 60 liters",
  "price": "$244.99",
  "related": [
    { "name": "Outdoor Odyssey Hiking Poles", "price": "$79.99" },
    { "name": "Outdoor Odyssey Sleeping Bag", "price": "$129.99" },
    { "name": "Outdoor Odyssey Water Bottle", "price": "$19.99" }
  ]
}
```

Supported value forms:

- `"<sel>"`: `textContent.trim()` of the first match.
- `""`: the matched element's own text (only inside a `fields` block).
- `["<sel>"]`: text of every match. Sugar for `[{"selector": "<sel>"}]`.
- `{"selector": "<sel>", "attr": "<name>"}`: attribute of the first match.
- `[{"selector": "<sel>", "fields": {…}}]`: array of records, each
  `fields` value resolved relative to the matched element.

A selector that matches nothing yields a null or empty field, not an error.
That's deliberate, but it means a stale selector fails quietly. If a run
comes back with blanks where you expected data, suspect the selectors or a
missing wait before you suspect the page.

The schema is parsed in Zig before the page-side walker runs, so malformed
schemas are rejected up front with a plain `Error: InvalidParams` rather
than a V8 stack trace.

## Cross-call state with `lp.*`

`/extract` and `/evaluate` each return one value per call. To carry data
between calls (capture a list on one page, walk it across navigations) use
the `save=` modifier:

```console
/goto 'https://news.ycombinator.com/'

/extract '''
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
''' save=front

/evaluate '''
console.log(lp.front.stories[0].title);
'''
```

`save=<name>` stashes the result keyed by `<name>` in a session-scoped
store instead of printing it. Every subsequent `/evaluate` sees it as
`globalThis.lp.<name>`.

Any mutation of `lp.*` inside `/evaluate` is persisted at the end of the
call. Adding (`lp.x = …`), updating
(`lp.front.stories[0].comments = […]`), or deleting (`delete lp.x`) all
propagate. The next `/evaluate` sees the update, even after a navigation,
because the store lives session-side, not on the page.

The store is **script-run scoped**: bound to the session that runs the
script, gone when that session ends. There's no cross-session persistence;
if you need that, use `localStorage` (origin-scoped, persists within a
session).

## JavaScript scripts

`./lightpanda agent script.js` runs a script without any LLM call. Scripts
are plain JavaScript plus the installed Lightpanda primitives:

```js
await goto("https://example.com");
click({ selector: "a.login" });
return evaluate("document.title");
```

`goto(url)` is **asynchronous** — always `await goto(...)`. Every other
primitive is **synchronous**: each returns its result directly, so write
`const data = extract(…)`, not `await extract(…)`. The script body runs as
an async function, so top-level `await` is allowed.

It's not Node.js. There's no `require`, `process`, `fs`, npm package
loading, or Node standard library. The `evaluate(...)` primitive runs its
string in the current page context; page scripts can't see agent variables
or agent primitives.

A script's output is whatever it `return`s, printed automatically, so a
script that ends with `return extract({...})` prints the extraction result
to stdout. A bare trailing expression is not printed. Tool errors throw
JavaScript exceptions (a `goto` failure rejects, so `await` throws) and stop
execution.

See [agent-script.md](agent-script.md) for the full script format reference.

### Saving and loading

`/save [file.js]` writes the current session to a `.js` file. `/load <path>`
runs a script from disk against the current session.

`/save` arguments are positional: the first token is the filename (`.js`
is appended when missing, so `/save test` writes `test.js`; quote names
with spaces) and anything after it is passed to the synthesizer as
guidance — `/save hn.js keep only the extraction`. With no argument at
all, the file gets an auto-generated `session-*.js` name.

`/save` works one of two ways, decided by the session rather than by any
argument — if the REPL has an LLM you get synthesis, with `--no-llm` (or
no resolved provider) you get the deterministic transcription:

- **With `--no-llm`** it transcribes the session deterministically.
  State-mutating commands (`/goto`, `/click`, `/fill`, `/scroll`, `/hover`,
  `/selectOption`, `/setChecked`, `/waitForSelector`, `/waitForScript`,
  `/waitForState`, `/press`, `/evaluate`, `/extract`) become JavaScript
  calls. Read-only
  commands (`/tree`, `/markdown`, `/links`, `/findElement`, ...) are
  dropped. Each natural-language prompt that produced recorded actions is
  written as a `// <prompt>` comment above its calls so the script stays
  readable.
- **With an LLM** it synthesizes an idiomatic script from the whole
  session. The synthesis prompt asks for JavaScript only ("no commentary"),
  so the result generally has no such comments: the model folds intent
  into the code and drops dead-ends. Output is whatever the script
  `return`s, which prints automatically on replay.

## One-shot mode (`--task`)

```console
./lightpanda agent --provider gemini \
  --task "what is the top story on news.ycombinator.com?"
```

`--task` runs a single user turn, prints the final answer to stdout, and
exits. On a TTY a spinner on stderr shows the tool currently running while
the agent works; raise `--verbosity` for the full `[tool/result]` trace.

Combine with `-a <path>` / `--attach <path>` (repeatable) to feed
local files to providers that accept attachments — for example, a list of
items to look up, or a document to cross-check against a live page:

```console
./lightpanda agent -a invoice.pdf \
  --task "open shop.example.com/orders/1042 and check the order total matches the attached invoice"
```

Text files are inlined
into the prompt (max 512 KiB each); binary files (image, audio, pdf) are
base64-encoded inline (max 20 MiB each). Unsupported MIME types fail before
any browser work runs.

`--task` conflicts with the positional script argument.

## Driving Lightpanda from an external LLM agent

When the calling agent already has its own LLM (e.g. Claude Code), use
`lightpanda mcp` rather than `lightpanda agent`. The MCP server exposes the
same browser tools listed below, so the external agent does the planning
while Lightpanda only drives the browser. No `--provider` or API key is
required on the Lightpanda side.

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

Tool names are camelCase and case-sensitive. MCP clients must call the
canonical tags (`goto`, `evaluate`, `tree`, `save`, ...).

For sub-task delegation in the other direction (calling Lightpanda's own
LLM-driven agent in a one-shot fashion), use `--task` on stdin.

### Saving a script over MCP

`lightpanda mcp` exposes a `save` tool so an external agent can persist the
session as a `.js` script for later deterministic replay. Unlike the
standalone agent's `/save`, the MCP server has no LLM of its own, so the
calling client holds the conversation and synthesizes the script itself.

| Tool   | Args                               | Effect                                                                                                                |
|--------|------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `save` | `{ path: string, script: string }` | Write `script` to `path` (relative, no `..`; created or overwritten) and return the absolute location and line count. |

The tool's description carries the same synthesis guidance the agent's
`/save` gives its LLM: prefer the builtins (`goto`, `click`, `fill`,
`extract`, ...) as JavaScript calls, drop dead-ends, keep `$LP_*`
placeholders. Any literal `LP_*` value is scrubbed back to its placeholder
before the file is written. The result runs without an LLM via
`./lightpanda agent session.js`.

## Browser tools

The agent and MCP server share the tool set defined in
`src/browser/tools.zig`. Highlights:

- `goto`, `search` (Tavily when `TAVILY_API_KEY` is set, DuckDuckGo
  otherwise)
- `tree`, `markdown`, `html`, `links`, `interactiveElements`,
  `structuredData`, `detectForms`, `nodeDetails`, `findElement`
- `click`, `fill`, `hover`, `press`, `scroll`, `selectOption`, `setChecked`,
  `waitForSelector`, `waitForScript`, `waitForState`
- `extract` (the schema-driven data tool), `evaluate`, `consoleLogs`,
  `getUrl`, `getCookies`, `getEnv`

Selectors prefer CSS over `backendNodeId` for the click-family tools since
node IDs are invalidated by any DOM mutation. The system prompt enforces
this for the LLM.

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
  reports "not set" so the model can't probe for it. `getEnv` returns the
  *value* to the model: fine for non-secret config like base URLs, never
  call it on credentials (use `$LP_*` placeholders in fill values instead).
- `--obey-robots`, `--http-proxy`, `--user-agent`, and the rest of the
  browser-level CLI flags apply to `agent` the same way they apply to
  `serve`, `fetch`, and `mcp`.
- REPL prompts are persisted to `.lp-history` in plaintext (no encryption).
  Anything you type at the prompt, including natural-language context that
  accompanies a `/login`, lands in that file. Delete it or move out of
  sensitive directories if you don't want it retained.
- `save` rejects empty, absolute, and `..` paths, but does **not** follow
  up on symlinks. On a shared filesystem, a pre-existing symlink at the
  target would be written through to whatever it points at. Prefer a fresh
  directory you own when saving in untrusted environments.
