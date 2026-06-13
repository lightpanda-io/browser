# Agent tutorial, Hacker News end-to-end

This tutorial will walk you through how to use Lightpanda Agent to create a
reproducible JavaScript browser script.

For flag and command tables, see [agent.md](agent.md).

## Prerequisites

- `./lightpanda` on your PATH.
- A Hacker News account.
- An LLM API key for the natural-language sections (Anthropic, OpenAI,
  Gemini, or a local Ollama). Recorded `.js` scripts need no key.

Export your HN credentials as `LP_*` env vars. The `LP_` prefix
matters for security: Lightpanda only resolves these placeholders
inside its own subprocess (so your password never reaches the LLM),
and the `getEnv` tool refuses any variable that doesn't start with
`LP_` (so the LLM can't read your other secrets).

```console
export LP_HN_USERNAME="your-hn-handle"
export LP_HN_PASSWORD="your-hn-password"
```

Check the variables are set. If one is missing, `/fill` will silently
type the literal `$LP_HN_USERNAME` into the form rather than your
username:

```console
./lightpanda agent --no-llm
> /getEnv LP_HN_USERNAME
```

## 1. Start the REPL

```console
./lightpanda agent
```

The startup banner shows whether natural language is available;
`/model` prints the resolved model. REPL history lives in `.lp-history`
in the working directory.

```
> /help            # list every browser tool
> /help goto       # JSON schema for one tool
> /quit
```

No API key? `./lightpanda agent --no-llm` runs the slash-commands-only
REPL.

## 2. Run a single task

Before doing anything complicated, run a one-shot task to check
everything works:

```console
./lightpanda agent --task "what is the top story on news.ycombinator.com?"
```

`--task` runs one user turn, prints the answer on stdout, exits.
Tool calls and progress go to stderr, so redirecting gives you a
clean answer:

```console
./lightpanda agent --task "top story on news.ycombinator.com?" > out.txt
```

Use `-a <path>` (repeatable) to attach local files.

## 3. Log in to Hacker News

Paste these into the REPL in order:

```
> /goto https://news.ycombinator.com/login
> /fill selector='form[action="login"] input[name="acct"]' value='$LP_HN_USERNAME'
> /fill selector='form[action="login"] input[name="pw"]' value='$LP_HN_PASSWORD'
> /click selector='form[action="login"] input[type="submit"][value="login"]'
> /waitForSelector '#logout'
```

A few things worth knowing:

- **Slash commands only.** `click '#foo'` is forwarded to the LLM;
  only `/click '#foo'` runs as a command. TAB completes tool names.
- **`/waitForSelector '#logout'` is both a sync point and an
  assertion.** It blocks until HN's logged-in DOM renders. If the
  credentials are wrong (or the website throws a captcha, or the layout
  changes), the command times out at the line where the failure
  actually happened. Use this pattern after every state-changing
  action.
- **Selectors are CSS only.** The click-family tools (`/click`,
  `/fill`, `/hover`, `/selectOption`, `/setChecked`) accept CSS
  only. Backend node IDs are invalidated by any DOM mutation and
  can't be serialized into recordings.

Confirm the login worked:

```
> /extract '{"karma": "#karma"}'
{"karma":"42"}
```

`/extract` takes a JSON schema and prints one JSON object to stdout.
Schema grammar:

- `"<sel>"`: text of the first match.
- `["<sel>"]`: text of every match.
- `{"selector": "<sel>", "attr": "<name>"}`: attribute of the first match.
- `[{"selector": "<sel>", "fields": {…}}]`: array of records, with
  each `fields` entry resolved relative to the matched element.

Now go to the front page and pull the story list:

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

Triple-quoted values let a schema span multiple lines.

### How we got those selectors

Skip this if you're happy treating them as given.

`/tree` prints the semantic tree. On the login page you'll see two
forms (login and signup) with unlabeled textboxes, which means
`/findElement role=textbox name=username` returns nothing.

`/detectForms` reads the HTML directly and surfaces each form's
`action` plus each input's `name`. The first form has `action: "login"`
and fields named `acct` and `pw`, which gives us the form-scoped
selector (`form[action="login"] input[name="acct"]`) that won't
collide with signup.

`/nodeDetails backendNodeId=<n>` is the alternative: it returns a
ready-to-use CSS selector for any node ID from `/tree`.

## 4. Save the session as a script

Retype the login plus front-page sequence in a single REPL session,
then:

```
> /save hn_login.js
> /quit
```

In `--no-llm` mode, `/save` transcribes the session deterministically.
With an LLM, it synthesizes an idiomatic script. The result is
JavaScript:

```js
await goto("https://news.ycombinator.com/login");
fill({ selector: "form[action=\"login\"] input[name=\"acct\"]", value: "$LP_HN_USERNAME" });
fill({ selector: "form[action=\"login\"] input[name=\"pw\"]", value: "$LP_HN_PASSWORD" });
click({ selector: "form[action=\"login\"] input[type=\"submit\"][value=\"login\"]" });
waitForSelector("#logout");
await goto("https://news.ycombinator.com");
return extract({ topStories: [{ selector: ".athing", fields: { rank: ".rank", title: ".titleline > a", url: { selector: ".titleline > a", attr: "href" } } }] });
```

Only state-mutating commands are recorded; read-only ones (`/tree`,
`/markdown`) are dropped. `/extract` is recorded because it shapes
what the script returns.

## 5. Replay the script without an LLM

```console
./lightpanda agent hn_login.js
```

No `--provider`, no API key, no token spend. The script's last
expression is printed automatically as JSON. Because the saved script
ends with `extract(...)`, you get clean JSON on stdout:

```console
./lightpanda agent hn_login.js > stories.json
```

From inside the REPL, `/load hn_login.js` runs the same script against
the current session.

To reshape the output, assign the result and end with a bare expression
(the final value is what prints):

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

topStories;
```

## 6. Add your own JavaScript logic

Agent scripts run in a separate JavaScript context from the page. No
`window`, `document`, DOM API, `require`, or `process`. Browser
interaction happens through the installed primitives.

Use `extract(...)` to move page data into local logic, then process it
with normal JavaScript:

```js
await goto("https://news.ycombinator.com");

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

return topStories.map((s) => ({ rank: s.rank, title: s.title, url: s.url }));
```

Use `evaluate(...)` only when you intentionally want a string to run in
the page's JavaScript context. Page evaluate cannot see agent
variables or call agent primitives.

## 7. Use Lightpanda from another agent (MCP)

If you're driving Lightpanda from a different agent (Claude Code, a
custom MCP client, your own harness), use `lightpanda mcp` instead.
The calling agent supplies the LLM, so Lightpanda needs no API key.

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

Drive the browser with the usual tools (`goto`, `fill`, `click`,
`waitForSelector`), then hand back a script with the `save` tool:

```json
{
  "tool": "save",
  "args": {
    "path": "hn_login.js",
    "script": "await goto(\"...\");\n..."
  }
}
```

The path must be relative and free of `..`. Literal `LP_*` values are
scrubbed back to placeholders before the file is written. The output
runs unmodified:

```console
./lightpanda agent hn_login.js
```

## What next?

- [agent.md](agent.md): full reference for every flag, slash command,
  and browser tool.
- [agent-script.md](agent-script.md): JavaScript runtime, primitives,
  return values.
- `lightpanda mcp --help` and `lightpanda agent --help`: current
  flags straight from the binary.
