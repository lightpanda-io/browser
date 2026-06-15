# Agent JavaScript scripts

`lightpanda agent <script.js>` runs a JavaScript file that drives a
Lightpanda browser session through a small set of blocking global functions.
The format is intentionally plain JavaScript: use normal variables, functions,
loops, objects, arrays, `JSON.parse`, `JSON.stringify`, and other standard
ECMAScript built-ins.

```console
./lightpanda agent session.js
```

The interactive REPL still uses slash commands. `/save` writes the recorded
browser actions as JavaScript calls so the saved file can be replayed without
an LLM.

## Runtime Environment

Agent scripts run in their own V8 context. That context is separate from the
web page's JavaScript context.

- It is not the browser page environment. There is no `window`, `document`,
  DOM, `localStorage`, `navigator`, or page global state in the agent script.
  Read page data with `extract(...)`, or explicitly run page JavaScript with
  `evaluate(...)` when that is the right tool.
- It is not Node.js. There is no `require`, `process`, `fs`, `path`, npm
  package loading, command-line argument API, or Node network/filesystem API.
- Page scripts cannot see agent variables or Lightpanda primitives. Agent
  scripts cannot directly see page variables.
- The global `evaluate(...)` primitive runs JavaScript in the page context,
  distinct from the agent context's own native `eval`.
- Agent variables persist for the lifetime of one script run, across
  navigations and primitive calls. A later `lightpanda agent script.js` run
  starts with a fresh agent context.
- `goto(url)` is asynchronous — always use `await goto(...)`. Every other primitive
  is synchronous; do not `await` them (`const data = extract({ ... })`, not
  `await extract(...)`). The script body runs as an async function, so top-level
  `await` is allowed. (`goto` returns a page handle for parallel fetches — see
  Navigation below.)
- Tool failures throw JavaScript `Error` exceptions (a `goto` failure rejects
  its Promise, so `await` throws) and stop execution unless you catch them.
- The script's output is whatever it `return`s, printed automatically (objects
  and arrays as JSON; other values coerced). End a script with `return
  extract({ ... });` or `return results;`. A bare trailing expression is not
  printed. `console.log(...)` is for extra or debug output and does not
  JSON-format objects.

The agent context includes a small `console` object:

```js
console.log("printed to stdout");
console.info("printed to stdout");
console.debug("printed to stdout");
console.warn("printed to stderr");
console.error("printed to stderr");
```

## Values And Return Types

Most primitives return the browser tool's result text as a JavaScript string.
`extract(...)` is the exception: it returns extracted data as a normal
JavaScript value, so local script logic can use it directly. The result mirrors
your schema — an object schema returns an object keyed by your fields (even with
a single field), and a bare array schema returns an array:

```js
await goto("https://news.ycombinator.com/");

const data = extract({
  title: "title",
  stories: [{
    selector: "tr.athing",
    limit: 5,
    fields: {
      id: { attr: "id" },
      title: ".titleline > a"
    }
  }]
});

return data; // printed automatically as JSON
```

Destructure when a single field is all you need:

```js
const { stories } = extract({
  stories: [{
    selector: "tr.athing",
    limit: 5,
    fields: {
      id: { attr: "id" },
      title: ".titleline > a"
    }
  }]
});

for (const story of stories) {
  console.log(story.title);
}
```

`evaluate(...)` still returns the page evaluate tool result text. When page `evaluate(...)`
returns an object or array, that text is JSON.

Primitive arguments must be JSON-serializable. Strings, numbers, booleans,
arrays, plain objects, and `null` work. `undefined`, functions, symbols, and
cyclic objects do not.

## Installed Primitives

Only recorded browser primitives are installed globally:

| Primitive | Arguments | Runs in |
|-----------|-----------|---------|
| `goto` | `await goto(url[, { timeout }])` (async; resolves a page handle) | Browser session |
| `extract` | `extract(schema[, page])` or `extract({ schema })` | Browser page via extractor; returns a JS object or array |
| `evaluate` | `evaluate(script[, { url, timeout, save }])` | Browser page JS context |
| `click` | `click(selector)` or `click({ selector })` | Browser page |
| `fill` | `fill(selector, value)` or `fill({ selector, value })` | Browser page |
| `scroll` | `scroll()` or `scroll({ x, y })` | Browser page |
| `waitForSelector` | `waitForSelector(selector[, { timeout }])` | Browser page |
| `waitForScript` | `waitForScript(script[, { timeout }])` | Browser page JS context |
| `waitForState` | `waitForState(state[, { timeout }])` | Browser page |
| `hover` | `hover(selector)` or `hover({ selector })` | Browser page |
| `press` | `press(selector, key)` or `press({ key[, selector] })` | Browser page |
| `selectOption` | `selectOption(selector, value)` or `selectOption({ selector, value })` | Browser page |
| `setChecked` | `setChecked(selector[, checked])` or `setChecked({ selector, checked })` | Browser page |

`goto` returns at the `load` event (a fast snapshot). When a page's content is
still loading (rendered by post-load JS), call `waitForState("networkidle")`
before reading. `waitForState`'s `state` accepts `"load"`,
`"domcontentloaded"`, `"networkalmostidle"`, `"networkidle"`, or `"done"`.
`goto`'s `timeout` defaults to 10000 ms; the `waitFor*` timeouts default to
5000 ms.

The `[, { … }]` is an optional trailing options object: leading arguments are
positional (`waitForSelector("#row", { timeout: 2000 })`), and the options ride
in a final object. Passing a single object with everything
(`waitForSelector({ selector: "#row", timeout: 2000 })`) is equivalent — that's
the shape `/save` records into saved scripts. An option can't be a bare
positional, though: `waitForSelector("#row", 2000)` is an error. A `null`
positional omits that field (`press(null, "Enter")` presses on the focused
element), and setting the same field positionally and in the options object
(`goto(url, { url: ... })`) is an `invalid arguments` error.

Script primitives address elements by CSS selector only. The tools that hand
out `backendNodeId`s (`tree`, `findElement`, `nodeDetails`) aren't installed in
the script context, and a raw node ID wouldn't survive replay anyway. When
you're exploring in the REPL and have a `backendNodeId` — e.g. the leading
number on a `/tree` line, or a `/findElement` hit — run `/nodeDetails
backendNodeId=<id>` to get a durable CSS `selector`, then paste that into your
script.

## Navigation

Use `await goto(...)` to open a page (it is asynchronous):

```js
await goto("https://example.com");

await goto({
  url: "https://example.com/app",
  timeout: 15000
});
```

The Promise resolves to a **page handle** and rejects if navigation fails. A
timeout does **not** reject: the page stays in whatever state it reached, so
follow with `waitForState(...)` / `waitForSelector(...)` when completeness
matters.

You only need the handle for **parallel** fetches: a single page at a time is
implicit (the read tools act on the latest `goto`), but to load several at once
and read each one, pass its handle as the optional last argument:

```js
const [a, b] = await Promise.all([
  goto("https://example.com/a"),
  goto("https://example.com/b"),
]);
const da = extract({ title: "h1" }, a);   // reads page a
const db = extract({ title: "h1" }, b);   // reads page b
```

The handle works on any page tool — `click(sel, a)`, `evaluate(js, a)`, etc.

Two limits to know:

- **Handle lifetime.** Pages from a parallel batch stay alive until the next
  *sequential* `goto` (one with nothing else in flight), which replaces them.
  So read a batch's handles before your next standalone `goto` — don't stash a
  handle across one.
- **Combined navigate-and-read stays single-page.** The `url` option on
  `markdown`/`html`/`tree`/`evaluate` (e.g. `markdown({ url })`) navigates the
  one current page, so it does not take part in parallel fetching. Use
  `await goto(url)` + a handle when you need concurrency.

## Structured Extraction

Use `extract(...)` to read data from the current page without writing page-side
JavaScript. This is the preferred bridge from page content into local agent
logic.

```js
const result = extract({
  heading: "h1",
  links: [{
    selector: "a",
    limit: 10,
    fields: {
      text: "",
      href: { attr: "href" }
    }
  }]
});
```

The schema forms are:

| Schema value | Meaning |
|--------------|---------|
| `"<selector>"` | Text of the first matching element, or `null` |
| `""` | Text of the current matched element inside a `fields` block |
| `["<selector>"]` | Text of all matching elements |
| `{ selector: "<selector>", attr: "<name>" }` | Attribute from the first match |
| `[{ selector: "<selector>", attr: "<name>" }]` | Attribute from all matches |
| `[{ selector: "<selector>", fields: { ... } }]` | Array of records, with fields resolved relative to each matched element |
| `limit: N` | Cap array extraction to `N` matches |

Return shape follows the top-level schema:

- `extract({ title: "h1" })` returns `{ title: "..." }`.
- `extract({ title: "h1", links: [{ selector: "a" }] })` returns an object
  with both fields.
- `extract({ links: [{ selector: "a" }] })` returns `{ links: [...] }` — an
  object schema always returns an object, even with a single field.
- `extract([{ selector: "a" }])` is shorthand for a single anonymous array
  extraction and returns the array directly.

Every value is a string (trimmed text or a raw attribute) or `null` — parse
numbers in script logic. An array field that matches nothing yields `[]`
without complaint (a page with zero comments is a valid result), but if
*every* field in the schema misses, `extract(...)` throws
`no schema selector matched any element` — treat that as "my selectors are
wrong", not "the page is empty".

`extract(...)` reads only the current page. For list-to-detail scraping —
capture a list, then visit each row for more — capture the list, then loop in
the script: `goto` each row's URL and `extract` the detail. The local agent
context keeps the data across navigations, so the assembly happens in plain
JavaScript. See the [complete example](#complete-example) below.

When passing an object directly to `extract(...)`, the runtime serializes it as
the extractor schema. These forms are equivalent:

```js
extract({ title: "h1" });
extract({ schema: { title: "h1" } });
extract('{ "title": "h1" }');
```

The wrapped form accepts only `schema`: the REPL's `save=` option does not
exist in scripts (`extract({ schema: ..., save: ... })` is rejected). Keep
results in local variables instead.

Use local variables to keep extracted data available to later script logic:

```js
const page = extract({ title: "title" });
```

## Page JavaScript

`evaluate(...)` is the explicit escape hatch into the current page's JavaScript
context. Its script string runs where `window` and `document` exist.

```js
await goto("https://example.com");

const title = evaluate("document.title");
console.log(title);
```

Keep the boundary clear:

```js
const selector = "h1";

// Good: local agent logic builds an extract schema.
const data = extract({ heading: selector });

// Bad: page evaluate cannot see local agent variables.
evaluate("document.querySelector(selector).textContent");
```

Page `evaluate(...)` cannot call `goto`, `extract`, or other agent primitives.
Agent scripts cannot access `document` directly. If you need page DOM data,
prefer `extract(...)`; use `evaluate(...)` only for page behavior that extraction
cannot express.

`waitForScript(...)` also evaluates in the page context, repeatedly, until the
expression is truthy or the timeout expires:

```js
waitForScript("document.querySelectorAll('.row').length >= 5");
```

## Interaction Primitives

The action primitives operate on the current page. Most take one object whose
fields match the browser tool schema:

```js
click({ selector: "a.login" });
fill({ selector: "input[name='acct']", value: "$LP_HN_USERNAME" });
fill({ selector: "input[name='pw']", value: "$LP_HN_PASSWORD" });
press({ key: "Enter" });

waitForSelector("#logout");

hover({ selector: "#menu" });
selectOption({ selector: "select[name='country']", value: "FR" });
setChecked({ selector: "input[name='terms']", checked: true });
setChecked({ selector: "input[name='newsletter']", checked: false });

scroll({ y: 600 });
scroll();
```

`setChecked` defaults `checked` to `true` when the field is omitted
(`setChecked("#chk")` checks the box). `press`'s leading positional is the
optional `selector`, not `key`: a bare `press("Enter")` binds `"Enter"` to
`selector` and fails. Press on the focused element with
`press({ key: "Enter" })` or `press(null, "Enter")`; target an element with
`press("#search", "Enter")` or `press({ key: "Enter", selector: "#search" })`.

`$LP_*` placeholders in string arguments are resolved inside the Lightpanda
process. This keeps credentials out of recorded scripts and LLM prompts. In
recordings, resolved `LP_*` values are scrubbed back to placeholders.

## Recording Format

The REPL remains slash-command based:

```text
> /goto https://example.com
> /click selector='a.login'
> /save
```

`/save` writes JavaScript by default:

```js
await goto("https://example.com");
click({ selector: "a.login" });
```

Only replayable browser actions are recorded:

- Recorded: `goto`, `click`, `fill`, `scroll`, `hover`, `press`,
  `selectOption`, `setChecked`, `waitForSelector`, `waitForScript`,
  `waitForState`, `evaluate`, and `extract` — the same set installed as script
  primitives.
- Not recorded: read-only exploration tools such as `tree`, `markdown`, `html`,
  `links`, `findElement`, `consoleLogs`, `getUrl`, `getCookies`, and `getEnv`.
- Natural-language prompts are written as `//` comments above the actions they
  produced.

This is the deterministic `--no-llm` transcription. When `/save` runs with an
LLM it instead synthesizes an idiomatic script from the session and is asked to
emit JavaScript only, so those `//` comments generally won't appear.

## Error Handling

Primitive failures throw JavaScript exceptions:

```js
try {
  waitForSelector({ selector: "#dashboard", timeout: 1000 });
} catch (err) {
  console.error("dashboard did not appear:", err.message);
  throw err;
}
```

Common failures:

| Error | Meaning |
|-------|---------|
| `ReferenceError: document is not defined` | You tried to use browser DOM APIs in the agent context. Use `extract(...)` or page `evaluate(...)`. |
| `ReferenceError: require is not defined` | Agent scripts are not Node.js scripts. |
| `no page loaded - run goto(url) first` | A page-dependent primitive ran before navigation. |
| `invalid arguments` | A primitive received the wrong number or shape of arguments, or a non-JSON-serializable value. |
| `extract: no schema selector matched any element` | Every field in the schema missed. Fix the selectors; an empty page section yields `null`/`[]` per field, not this error. |

## Complete Example

This script opens Hacker News, extracts five stories, visits each comments
page, and prints one JSON object. The looping and object assembly happen in
the local agent script, not in the page.

```js
const HN = "https://news.ycombinator.com";

await goto(HN);

const { stories } = extract({
  stories: [{
    selector: "tr.athing",
    limit: 5,
    fields: {
      id: { attr: "id" },
      title: ".titleline > a",
      url: { selector: ".titleline > a", attr: "href" }
    }
  }]
});

for (const story of stories) {
  story.comments = [];
  if (!story.id) continue;

  await goto(`${HN}/item?id=${story.id}`);
  const { comments } = extract({
    comments: [{
      selector: "tr.athing.comtr:has(.commtext)",
      limit: 3,
      fields: {
        author: ".hnuser",
        text: ".commtext"
      }
    }]
  });
  story.comments = comments;
}

return stories; // printed automatically as JSON
```
