# Agent tutorial — Hacker News, end-to-end

This walks you from "I just built `./lightpanda`" to a recorded,
replayable JavaScript browser script, then captures the same flow from
an external MCP client. Every section ends with a command you can run;
nothing references later sections.

For the flag/command/tool tables, see [agent.md](agent.md). This
document is the tutorial; that one is the reference. For the JavaScript
runtime contract, see [agent-script.md](agent-script.md).

## What you'll build

One session against Hacker News:

1. Log in with your account.
2. Confirm the login by reading the username out of the header.
3. Save the whole flow to a `.js` file.
4. Run it offline, with no LLM.
5. Add local JavaScript logic around `extract(...)` results.
6. Save the same flow as a script from an external agent over MCP.

## Prerequisites

- `./lightpanda` on your PATH (build with `zig build`).
- A Hacker News account.
- One LLM API key for sections that use natural language — Anthropic,
  OpenAI, Gemini, or a local Ollama. Recorded `.js` scripts run with no
  key at all.

Export your HN credentials as `LP_*` env vars. The convention is
`LP_<SITE>_<FIELD>` — a short site identifier (`HN` for Hacker News,
`GH` for GitHub, …) lets you keep credentials for multiple sites in
your environment without collisions. The unprefixed `LP_USERNAME` /
`LP_PASSWORD` form is the generic fallback when you only have one
site.

In **bash** or **zsh**:

```console
export LP_HN_USERNAME="your-hn-handle"
export LP_HN_PASSWORD="your-hn-password"
```

In **fish**:

```fish
set -gx LP_HN_USERNAME "your-hn-handle"
set -gx LP_HN_PASSWORD "your-hn-password"
```

The `LP_` prefix matters. The agent resolves `$LP_*` references
*inside* the Lightpanda subprocess, so the literal secret never enters
the LLM context; and the `getEnv` tool refuses to read anything that
doesn't start with `LP_`, so the model can't probe your other env
vars.

Verify they're set before continuing — substitution fails silently if
a variable is missing (the literal `$LP_HN_USERNAME` ends up typed
into the form), and the `/fill` confirmation message intentionally
echoes the placeholder name rather than the resolved value, so the
response text won't tell you. Confirm directly:

```console
./lightpanda agent --no-llm
> /getEnv LP_HN_USERNAME
```

`/getEnv` returns the literal value if set, or "not set" if missing.
Only `$LP_*` references in fill values are substituted; other `$`
characters in your password (`my$ecret`, `$5.99`) are passed through
verbatim.

## 1. First contact: the REPL

```console
./lightpanda agent
```

On startup the agent prints a `Lightpanda Agent (version)` banner. The
status bar under the prompt then shows the model it resolved (a detected
cloud key, or a local Ollama server if that's all it finds), and the help
line tells you whether natural language is available or you're in the
basic `--no-llm` REPL. The REPL writes its history to `.lp-history` in the
working directory, so up-arrow works across runs.

Try the meta commands:

```
> /help
> /help goto
> /quit
```

`/help` lists every browser tool. `/help <tool>` prints its JSON
schema. `/quit` exits cleanly. If you have no API key yet and want to
poke around without an LLM, `./lightpanda agent --no-llm` forces the
basic REPL.

## 2. The shortest possible win: `--task`

Before doing anything complicated, prove the LLM + browser stack
works end-to-end:

```console
./lightpanda agent --task "what is the top story on news.ycombinator.com?"
```

`--task` runs a single user turn, prints the final answer on stdout,
and exits. Tool calls, progress, and errors all go to stderr, so
redirecting stdout gives you a clean answer:

```console
./lightpanda agent --task "top story on news.ycombinator.com?" > out.txt
```

If you need to feed the model a local file, repeat
`-a <path>` (or `--attach <path>`) for each one.

## 3. Driving the browser by hand

Now back to the REPL. We'll write the HN login flow one command at a
time so you can see how each step depends on what the previous one
showed.

```
> /goto https://news.ycombinator.com/login
```

`/goto` takes a single URL argument (positional, optionally quoted). The page
is now loaded.

> The REPL scripting surface is slash commands. `click '#foo'` (no leading slash) is
> forwarded to the LLM as a natural-language prompt; only `/click '#foo'`
> runs as a command. TAB completion in the REPL helps you find the right
> tool name.

Inspect it before clicking anything:

```
> /tree
```

`/tree` prints the semantic tree to stdout. Two forms are visible —
the login form and the create-account form below it — and each one
contains two unlabeled textboxes:

```
8 form
 13 'username:'
 15 [i] textbox
 18 'password:'
 20 [i]
 22 [i] button 'login' value='login'
30 form
 35 'username:'
 37 [i] textbox
 …
```

Notice the textboxes have no accessible name — "username:" is a
sibling text node, not a `<label for="…">`. This is typical of older
pages. The ARIA-name tool reflects that:

```
> /findElement role=textbox name=username
[]
```

Empty result. Slash commands accept a single positional argument
(for tools with one required field), `key=value` pairs, or a raw
`{json}` blob; `findElement` filters by accessible name, which we
don't have here.

For unlabeled login forms, jump to `detectForms`, which reads the
HTML directly and surfaces each form's `action` plus each input's
`name` attribute:

```
> /detectForms
```

You'll see two forms, the first with `action: "login"` and fields
named `acct` and `pw`. That's enough to synthesize the CSS selector
yourself: scope by form action to avoid colliding with the
create-account form, then key on the input's `name` attribute.

**Selector rule, load-bearing:** the click-family tools (`/click`,
`/fill`, `/hover`, `/selectOption`, `/setChecked`) accept CSS selectors
only. The backend node IDs `findElement` and `detectForms` return are
invalidated by any DOM mutation, and they cannot be serialized into
durable JavaScript recordings — a session that uses them is not
replayable. Always
synthesize a CSS selector from the attributes (`id`, `class`,
`name`, `action`, `tag_name`) and use that.

You don't have to hand-roll the selector. Every node in the `/tree`
output carries a `backendNodeId` (the leading number on each line), and
`/nodeDetails` turns one into a durable selector for you:

```
> /nodeDetails backendNodeId=15
```

It returns a ready-to-use CSS `selector` that resolves to that node
(plus its tag, id, class, name, and attributes) — the canonical way to
go from a `/tree` (or `/findElement`) hit to a selector you can paste
into `/click` or `/fill`. We reached for `/detectForms` above because
the two login/signup forms share field names, so a form-scoped selector
(keyed on `action`) is cleaner here — but `/nodeDetails` is the quickest
path whenever you have a single `backendNodeId` and just want its
selector without guessing.

Now fill the form:

```
> /fill selector='form[action="login"] input[name="acct"]' value='$LP_HN_USERNAME'
> /fill selector='form[action="login"] input[name="pw"]' value='$LP_HN_PASSWORD'
> /click selector='form[action="login"] input[type="submit"][value="login"]'
> /waitForSelector '#logout'
```

`$LP_*` references in `/fill` values are resolved at execution time
inside the subprocess. The LLM never sees the literal credential.

The `/waitForSelector '#logout'` line is doing two jobs at once, and it's
worth unpacking because the pattern recurs in every recorded script:

- **It's a synchronization point.** `/click` on the submit button
  returns as soon as the click dispatches, not after the server
  responds. Without a wait, the next command races the login redirect
  and may run against the *pre-login* DOM. `/waitForSelector '<sel>'`
  blocks until that selector appears, so the script resumes only after
  HN's logged-in page has rendered.
- **It's an implicit assertion.** HN renders the `#logout` link only
  when the session is authenticated. If the credentials are wrong (or
  HN throws up a captcha, or rate-limits, or the form layout
  changed), `#logout` never appears and `/waitForSelector` times out —
  the script fails loudly at the line where the failure actually
  happened, instead of silently succeeding and producing garbage
  downstream.

You generally want a `/waitForSelector` like this after every state-changing
action that triggers async work: pick a selector that *only* exists
in the post-action state, and you get free regression protection.
Waiting on the URL (`location.pathname === "/news"`) or a generic
element that exists on both pages is weaker — both can be true before
the navigation finishes.

Confirm by pulling structured data off the page. `/extract` takes a
JSON schema object — each value describes what to lift out, and the
whole result is printed to stdout as one JSON object. The simplest
form is a flat selector lookup:

```
> /extract '{"karma": "#karma"}'
{"karma":"42"}
```

The schema grammar is small but covers the cases you'd reach for:

- `"<sel>"` — `textContent.trim()` of the first match (string, or
  `null` if no match).
- `""` — the matched element's own text (only meaningful inside a
  `fields` block, where there's an outer element to refer to).
- `["<sel>"]` — text of every match (string array).
- `{"selector": "<sel>", "attr": "<name>"}` — the first match's
  attribute value.
- `[{"selector": "<sel>", "fields": {…}}]` — array of objects, where
  each `fields` entry is resolved relative to the matched element.

After a page-changing action (click, navigation, form submit) the
previous `/tree` snapshot is stale; re-inspect before the next
interaction. Hop back to the front page and pull the story list to
exercise the structured form:

```
> /goto https://news.ycombinator.com
> /extract '''
{
  "topStories": [{
    "selector": ".athing",
    "fields": {
      "rank": ".rank",
      "title": ".titleline > a",
      "url": {"selector": ".titleline > a", "attr": "href"}
    }
  }]
}
'''
```

Triple-quoted (`'''` or `"""`) values let a schema span multiple lines
— the REPL keeps reading until it sees the matching closing quote.
The result is a single JSON object printed to stdout:
`{"topStories":[{"rank":"1","title":"…","url":"…"}, …]}`.

The schema is parsed in Zig before the page-side walker runs, so a
typo like a stray comma surfaces here as a plain `Error: InvalidParams`
instead of a confusing V8 stack trace.

## 4. Saving the session

The same flow, but exported to a file. In the same REPL, retype the
sequence — login (`/goto`, two `/fill`s, `/click`, `/waitForSelector`),
then the front-page hop and structured pull (`/goto`, multi-line
`/extract`) — then save it:

```
> /save hn_login.js
```

In the basic REPL (`--no-llm`) `/save` transcribes the session
deterministically; with an LLM it synthesizes an equivalent idiomatic
script. Either way `/quit` when you're done.

Inspect the result:

```console
cat hn_login.js
```

You should see the seven mutating commands and nothing else — no
`/tree`, no `/markdown`, no read-only lookups. `/save` filters on a
per-tool flag (`ToolDef.recorded`) so read-only inspection never
pollutes the script; `/extract` *is* recorded (it changes what the
script can read on replay even though it doesn't mutate the page).
The saved file is JavaScript:

```js
goto("https://news.ycombinator.com/login");
fill({ selector: "form[action=\"login\"] input[name=\"acct\"]", value: "$LP_HN_USERNAME" });
fill({ selector: "form[action=\"login\"] input[name=\"pw\"]", value: "$LP_HN_PASSWORD" });
click({ selector: "form[action=\"login\"] input[type=\"submit\"][value=\"login\"]" });
waitForSelector("#logout");
goto("https://news.ycombinator.com");
extract({ topStories: [{ selector: ".athing", fields: { rank: ".rank", title: ".titleline > a", url: { selector: ".titleline > a", attr: "href" } } }] });
```

Natural-language REPL turns are never saved as executable JavaScript.
In the deterministic `--no-llm` transcription, the prompt that produced
a set of recorded actions is kept as a `//` comment above them, so the
script stays readable. The LLM `/save` path is different: it rewrites
the whole session into an idiomatic script and is told to emit
JavaScript only, so it generally drops those comments rather than
preserving them verbatim.

## 5. Running deterministically

```console
./lightpanda agent hn_login.js
```

No `--provider`, no LLM, no token spend. The saved script runs top
to bottom against a fresh browser. This is the form you want for
regression tests and CI. From inside the REPL, `/load hn_login.js`
runs the same script against the current session.

The script's completion value — its last top-level expression — is
printed automatically (objects and arrays as JSON). Because the saved
script ends with the `extract(...)` call, you already get clean JSON on
stdout with nothing to edit:

```console
./lightpanda agent hn_login.js > stories.json
```

If you want to reshape the output first, assign the result and end with
a bare expression — that final value is what prints:

```js
const topStories = extract({
  topStories: [{
    selector: ".athing",
    fields: {
      rank: ".rank",
      title: ".titleline > a",
      url: { selector: ".titleline > a", attr: "href" }
    }
  }]
});

topStories; // printed automatically as JSON
```

`/login` and `/acceptCookies` are REPL-only LLM triggers. A script
saved with `/save` never contains them; `/save` captures the resulting
browser tool calls instead. Lines that are neither slash commands nor
comments are also REPL-only conveniences, not script syntax.

## 6. Local JavaScript logic

Agent scripts run in a separate JavaScript context from the web page.
There is no `window`, `document`, DOM API, `require`, `process`, or
Node standard library in that context. Browser interaction happens
through the installed primitives, and `extract(...)` is the usual way
to move page data into local script logic.

For example, turn the extraction result into a smaller report without
running any page-side JavaScript:

```js
goto("https://news.ycombinator.com");

const topStories = extract({
  topStories: [{
    selector: ".athing",
    limit: 5,
    fields: {
      rank: ".rank",
      title: ".titleline > a",
      url: { selector: ".titleline > a", attr: "href" }
    }
  }]
});

const report = topStories.map((story) => ({
  rank: story.rank,
  title: story.title,
  url: story.url
}));

report; // printed automatically as JSON
```

Use the `evaluate(...)` primitive only when you intentionally want to run a
string in the current page's JavaScript context. Page evaluate cannot see
agent variables or call `goto`, `extract`, and the other agent
primitives.

## 7. Same flow, external agent (MCP)

Everything above used Lightpanda's built-in agent. If you're driving
Lightpanda from a different agent (Claude Code, a custom MCP client,
your own harness), use `lightpanda mcp` instead — same browser tools,
no API key on the Lightpanda side, the calling agent supplies the
LLM.

Register the server with your MCP client:

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

### Save a script over MCP

The MCP server has no LLM of its own — your external agent is the brain.
Drive the browser with the usual tools, then hand back a script with the
`save` tool:

1. Run the browser tools you'd call anyway: `goto`, `fill`, `click`,
   `waitForSelector`. The server resolves `$LP_*` placeholders inside the
   subprocess, so credentials never reach your agent's context.
2. When the task is done, synthesize a `.js` script from the steps that
   mattered — call the builtins as JavaScript functions with the same
   object arguments — and call `save { "path": "hn_login.js", "script":
   "goto(\"...\");\n..." }`. The path must be relative and free of `..`;
   the response reports the absolute location and line count.

The `save` tool's description carries the same guidance the REPL's
`/save` gives its LLM (prefer builtins, drop dead-ends, keep `$LP_*`
placeholders), and any literal `LP_*` value is scrubbed back to its
placeholder before the file is written. The output uses the same
JavaScript format as `/save hn_login.js` from section 4 and runs
unmodified:

```console
./lightpanda agent hn_login.js
```

## Where to go next

- [agent.md](agent.md) — full reference: every flag, every slash
  command, every browser tool, plus the security model and
  auto-detection rules.
- [agent-script.md](agent-script.md) — JavaScript runtime, primitives,
  return values, and complete script examples.
- `lightpanda mcp --help` and `lightpanda agent --help` — current
  flag listings straight from the binary.
