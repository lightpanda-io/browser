# Agent tutorial — Hacker News, end-to-end

This walks you from "I just built `./lightpanda`" to a recorded,
replayable, self-healing browser script — and then drives the same
script from an external MCP client. Every section ends with a command
you can run; nothing references later sections.

For the flag/command/tool tables, see [agent.md](agent.md). This
document is the tutorial; that one is the reference.

## What you'll build

One session against Hacker News:

1. Log in with your account.
2. Confirm the login by reading the username out of the header.
3. Record the whole flow to a `.lp` file.
4. Replay it offline, with no LLM.
5. Break a selector on purpose; watch `--self-heal` repair the file.
6. Drive the same script from an external agent over MCP.

The finished artifact already exists in the repo as
[`hn_login.lp`](../hn_login.lp). Diff your recording against it at the
end as a sanity check.

## Prerequisites

- `./lightpanda` on your PATH (build with `zig build`).
- A Hacker News account.
- One LLM API key for sections that need natural language and
  self-healing — Anthropic, OpenAI, Gemini, or a local Ollama. Sections
  4–7 work with no key at all.

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
into the form), and the `TYPE` confirmation message intentionally
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

On startup the agent prints a one-line notice telling you which mode it
landed in — which provider (and which env var won), or "basic REPL
(no LLM)" if no key is set. The REPL writes its history to
`.lp-history` in the working directory, so up-arrow works across runs.

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
`--task-attachment <path>` for each one.

## 3. Driving the browser by hand

Now back to the REPL. We'll write the HN login flow one command at a
time so you can see how each step depends on what the previous one
showed.

```
> GOTO https://news.ycombinator.com/login
```

`GOTO` takes an unquoted URL. The page is now loaded.

> Commands must be uppercase. `click '#foo'` is forwarded to the LLM as
> natural language; only `CLICK '#foo'` runs as a command. TAB
> completion in the REPL fills in the caps for you — typing `cli<TAB>`
> rewrites the line to `CLICK`.

Inspect it before clicking anything:

```
> TREE
```

`TREE` prints the semantic tree to stdout. Two forms are visible —
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

**Selector rule, load-bearing:** the click-family tools (`CLICK`,
`TYPE`, `HOVER`, `SELECT`, `CHECK`) accept CSS selectors only. The
backend node IDs `findElement` and `detectForms` return are
invalidated by any DOM mutation, and they cannot be serialized into
PandaScript — a session that uses them is not replayable. Always
synthesize a CSS selector from the attributes (`id`, `class`,
`name`, `action`, `tag_name`) and use that.

Now fill the form:

```
> TYPE 'form[action="login"] input[name="acct"]' '$LP_HN_USERNAME'
> TYPE 'form[action="login"] input[name="pw"]' '$LP_HN_PASSWORD'
> CLICK 'form[action="login"] input[type="submit"][value="login"]'
> WAIT '#logout'
```

`$LP_*` references in `TYPE` values are resolved at execution time
inside the subprocess. The LLM never sees the literal credential.

The `WAIT '#logout'` line is doing two jobs at once, and it's worth
unpacking because the pattern recurs in every recorded script:

- **It's a synchronization point.** `CLICK` on the submit button
  returns as soon as the click dispatches, not after the server
  responds. Without a wait, the next command races the login redirect
  and may run against the *pre-login* DOM. `WAIT '<selector>'` blocks
  until that selector appears, so the script resumes only after HN's
  logged-in page has rendered.
- **It's an implicit assertion.** HN renders the `#logout` link only
  when the session is authenticated. If the credentials are wrong (or
  HN throws up a captcha, or rate-limits, or the form layout
  changed), `#logout` never appears and `WAIT` times out — the script
  fails loudly at the line where the failure actually happened,
  instead of silently succeeding and producing garbage downstream.

You generally want a `WAIT` like this after every state-changing
action that triggers async work: pick a selector that *only* exists
in the post-action state, and you get free regression protection.
Waiting on the URL (`location.pathname === "/news"`) or a generic
element that exists on both pages is weaker — both can be true before
the navigation finishes.

Confirm by pulling structured data off the page. `EXTRACT` takes a
JSON schema object — each value describes what to lift out, and the
whole result is printed to stdout as one JSON object. The simplest
form is a flat selector lookup:

```
> EXTRACT '{"karma": "#karma"}'
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
previous `TREE` snapshot is stale; re-inspect before the next
interaction. Hop back to the front page and pull the story list to
exercise the structured form:

```
> GOTO https://news.ycombinator.com
> EXTRACT '''
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
typo like a stray comma surfaces here as `Error: invalid EXTRACT
schema JSON` instead of a confusing V8 stack trace.

## 4. Recording the session

The same flow, but recorded to a file. Quit the REPL, then:

```console
./lightpanda agent -i hn.lp
```

`-i <path>` opens an interactive REPL that appends state-mutating
commands to `<path>`. Retype the same sequence — login (`GOTO`, two
`TYPE`s, `CLICK`, `WAIT`), then the front-page hop and structured
pull (`GOTO`, multi-line `EXTRACT`) — then `/quit`.

Inspect the result:

```console
cat hn.lp
```

You should see the seven mutating commands and nothing else — no
`TREE`, no `MARKDOWN`, no slash-command lookups. The recorder filters
on a per-command flag (`Command.isRecorded()`) so read-only inspection
never pollutes the script; `EXTRACT` *is* recorded (it changes what
the script will output on replay even though it doesn't mutate the
page).

Diff it against the checked-in fixture:

```console
diff hn.lp hn_login.lp
```

Modulo trailing newlines, they should match. That fixture is what the
rest of this tutorial uses.

## 5. Replaying deterministically

```console
./lightpanda agent hn_login.lp
```

No `--provider`, no LLM, no token spend. The recorded script runs
top to bottom against a fresh browser. This is the form you want for
regression tests and CI: it's pure replay.

`LOGIN`, `ACCEPT_COOKIES`, and natural-language lines are the only
script entries that require an LLM. A pure recording from `-i` never
contains them, so it always replays without `--provider`.

## 6. Selector drift and `--self-heal`

Real pages change. Simulate selector drift by editing your copy:

```console
cp hn_login.lp hn_broken.lp
sed -i 's/input\[name="acct"\]/input[name="user"]/' hn_broken.lp
```

`input[name="user"]` doesn't exist on HN's login form, so a plain
replay fails:

```console
./lightpanda agent hn_broken.lp
```

`TYPE`, `CHECK`, and `SELECT` go a step further than just "did the
selector resolve" — a post-exec verifier checks that the DOM
actually reflects the intent (the input ended up with the value you
typed, the checkbox flipped, the option got selected). That's what
catches silent drift before it propagates.

Now re-run with self-heal:

```console
./lightpanda agent --self-heal --provider anthropic hn_broken.lp
```

(Substitute your provider.) On failure, the agent runs a short,
budget-capped LLM turn against the *current* page state, gets a
replacement command, runs it, and atomically rewrites `hn_broken.lp`
in place. A `hn_broken.lp.bak` is written before any mutation, and
the rewritten line is prefixed with a header:

```pandascript
# [Auto-healed] Original: TYPE 'form[action="login"] input[name="user"]' '$LP_USERNAME'
TYPE 'form[action="login"] input[name="acct"]' '$LP_USERNAME'
```

Self-heal is intentionally narrow: one replacement per failure, no
navigation, capped budget. It's there to recover from selector
drift, not to redesign the script.

Re-run without `--self-heal` to prove replay is back to deterministic:

```console
./lightpanda agent hn_broken.lp
```

## 7. Same script, external agent (MCP)

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

### Record a session over MCP

From the external agent, call:

1. `record_start { "path": "hn.lp" }` — begins appending state-mutating
   tool calls to `hn.lp`. The path must be relative and free of `..`.
2. The same browser tools you'd call anyway: `goto`, `fill`, `click`,
   `waitForSelector`. Each one that succeeds is appended verbatim;
   query-only tools (`tree`, `markdown`, `findElement`, `consoleLogs`)
   are never recorded.
3. `record_comment { "text": "logged in" }` — drop a breadcrumb above
   the next recorded line. Useful for marking the boundary between
   LLM-driven phases.
4. `record_stop {}` — closes the recording and returns
   `{path, line_count}`.

The output file is byte-equivalent to what `-i hn.lp` produced in
section 4. It replays via the agent CLI without modification:

```console
./lightpanda agent hn.lp
```

### Replay with self-heal over MCP

MCP doesn't carry a `--self-heal` flag — self-heal is a two-tool
roundtrip the calling agent orchestrates:

1. Read the script. For each non-blank, non-comment line, call
   `script_step { "line": "<line>" }`. Comments and blanks are no-ops
   on the Lightpanda side.
2. On `isError: true`, the structured error message tells you what
   failed. Hand the current page state and the failing line to your
   own LLM; have it return a replacement PandaScript line (or
   several).
3. Call `script_heal { "path": "...", "replacements":
   [{ "original_line": "...", "replacement_lines": ["..."] }] }`.
   Each `original_line` must match verbatim. Lightpanda writes
   `<path>.bak` first, then atomically rewrites the file with the
   `# [Auto-healed] Original: …` header prepended to the first
   replacement — same format as section 6.
4. Continue from the next line.

`script_step` deliberately does *not* auto-record: the script is
already the source of truth during replay, so double-recording would
diverge the file from itself. `LOGIN`, `ACCEPT_COOKIES`, and
natural-language lines are rejected — those need an LLM, which is the
caller's responsibility.

## Where to go next

- [agent.md](agent.md) — full reference: every flag, every PandaScript
  command, every browser tool, plus the security model and
  auto-detection rules.
- [`hn_login.lp`](../hn_login.lp) — the fixture this tutorial builds.
- `lightpanda mcp --help` and `lightpanda agent --help` — current
  flag listings straight from the binary.
