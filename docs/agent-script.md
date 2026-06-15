# Agent JavaScript scripts

`lightpanda agent <script.js>` runs a JavaScript file that drives a
Lightpanda browser session. Pages are created with the global `Page` class —
`new Page()` makes a page and `await page.goto(url)` navigates it; every other
browser action is a method on that page (`page.extract(...)`, `page.click(...)`,
…). The format is intentionally plain JavaScript: use normal variables,
functions, loops, objects, arrays, `JSON.parse`, `JSON.stringify`, and other
standard ECMAScript built-ins.

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
  Read page data with `page.extract(...)`, or explicitly run page JavaScript
  with `page.evaluate(...)` when that is the right tool.
- It is not Node.js. There is no `require`, `process`, `fs`, `path`, npm
  package loading, command-line argument API, or Node network/filesystem API.
- Page scripts cannot see agent variables or Lightpanda primitives. Agent
  scripts cannot directly see page variables.
- `page.evaluate(...)` runs JavaScript in the page context, distinct from the
  agent context's own native `eval`.
- Agent variables persist for the lifetime of one script run, across
  navigations and primitive calls. A later `lightpanda agent script.js` run
  starts with a fresh agent context.
- `page.goto(url)` is asynchronous — always use `await page.goto(...)`. Every
  other page method is synchronous; do not `await` them (`const data =
  page.extract({ ... })`, not `await page.extract(...)`). The script body runs
  as an async function, so top-level `await` is allowed.
- Tool failures throw JavaScript `Error` exceptions (a `goto` failure rejects
  its Promise, so `await` throws) and stop execution unless you catch them.
- The script's output is whatever it `return`s, printed automatically (objects
  and arrays as JSON; other values coerced). End a script with `return
  page.extract({ ... });` or `return results;`. A bare trailing expression is not
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

Most page methods return the browser tool's result text as a JavaScript string.
`page.extract(...)` is the exception: it returns extracted data as a normal
JavaScript value, so local script logic can use it directly. The result mirrors
your schema — an object schema returns an object keyed by your fields (even with
a single field), and a bare array schema returns an array:

```js
const page = new Page();
await page.goto("https://news.ycombinator.com/");

const data = page.extract({
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
const { stories } = page.extract({
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

`page.evaluate(...)` returns the page evaluate tool result text. When page
`evaluate(...)` returns an object or array, that text is JSON.

Primitive arguments must be JSON-serializable. Strings, numbers, booleans,
arrays, plain objects, and `null` work. `undefined`, functions, symbols, and
cyclic objects do not.

## Installed Primitives

`Page` is the only global. `new Page()` makes a page object; every browser
primitive is a method on it. `page.goto` navigates; `page.close` frees the
page; everything else reads or acts on the loaded document:

| Primitive | Arguments | Runs in |
|-----------|-----------|---------|
| `Page` | `new Page()` (no navigation yet) | Agent context |
| `page.goto` | `await page.goto(url[, { timeout }])` (async) | Browser session |
| `page.close` | `page.close()` | Browser session |
| `page.extract` | `page.extract(schema)` or `page.extract({ schema })` | Browser page via extractor; returns a JS object or array |
| `page.evaluate` | `page.evaluate(script[, { url, timeout, save }])` | Browser page JS context |
| `page.click` | `page.click(selector)` or `page.click({ selector })` | Browser page |
| `page.fill` | `page.fill(selector, value)` or `page.fill({ selector, value })` | Browser page |
| `page.scroll` | `page.scroll()` or `page.scroll({ x, y })` | Browser page |
| `page.waitForSelector` | `page.waitForSelector(selector[, { timeout }])` | Browser page |
| `page.waitForScript` | `page.waitForScript(script[, { timeout }])` | Browser page JS context |
| `page.waitForState` | `page.waitForState(state[, { timeout }])` | Browser page |
| `page.hover` | `page.hover(selector)` or `page.hover({ selector })` | Browser page |
| `page.press` | `page.press(selector, key)` or `page.press({ key[, selector] })` | Browser page |
| `page.selectOption` | `page.selectOption(selector, value)` or `page.selectOption({ selector, value })` | Browser page |
| `page.setChecked` | `page.setChecked(selector[, checked])` or `page.setChecked({ selector, checked })` | Browser page |

`page.goto` returns at the `load` event (a fast snapshot). When a page's content
is still loading (rendered by post-load JS), call
`page.waitForState("networkidle")` before reading. `waitForState`'s `state`
accepts `"load"`, `"domcontentloaded"`, `"networkalmostidle"`, `"networkidle"`,
or `"done"`. `goto`'s `timeout` defaults to 10000 ms; the `waitFor*` timeouts
default to 5000 ms.

The `[, { … }]` is an optional trailing options object: leading arguments are
positional (`page.waitForSelector("#row", { timeout: 2000 })`), and the options
ride in a final object. Passing a single object with everything
(`page.waitForSelector({ selector: "#row", timeout: 2000 })`) is equivalent —
that's the shape `/save` records into saved scripts. An option can't be a bare
positional, though: `page.waitForSelector("#row", 2000)` is an error. A `null`
positional omits that field (`page.press(null, "Enter")` presses on the focused
element), and setting the same field positionally and in the options object
(`page.goto(url, { url: ... })`) is an `invalid arguments` error.

Page methods address elements by CSS selector only. The tools that hand out
`backendNodeId`s (`tree`, `findElement`, `nodeDetails`) aren't installed in the
script context, and a raw node ID wouldn't survive replay anyway. When you're
exploring in the REPL and have a `backendNodeId` — e.g. the leading number on a
`/tree` line, or a `/findElement` hit — run `/nodeDetails backendNodeId=<id>` to
get a durable CSS `selector`, then paste that into your script.

## Navigation

Create a page with `new Page()`, then `await page.goto(...)` to navigate it (it
is asynchronous). A fresh `new Page()` has no document yet — call `page.goto`
before any other method, or you get `page is not navigated or has been closed`.

```js
const page = new Page();
await page.goto("https://example.com");

await page.goto({
  url: "https://example.com/app",
  timeout: 15000
});
```

The Promise resolves to the page object (the same one) and rejects if navigation
fails. A timeout does **not** reject: the page stays in whatever state it
reached, so follow with `page.waitForState(...)` / `page.waitForSelector(...)`
when completeness matters.

**Re-navigating reuses the same page object.** Calling `page.goto` again moves
the page to a new document; the object stays valid, so there's no rebind to
track:

```js
const page = new Page();
await page.goto("https://example.com");
page.click("#next");
await page.goto("https://example.com/step2"); // same `page`, now on step2
const data = page.extract({ title: "h1" });
```

For **parallel** fetches, make several pages and navigate them together with
`Promise.all`. Those pages coexist (they open as popup frames) and each is read
through its own page object:

```js
const a = new Page();
const b = new Page();
await Promise.all([
  a.goto("https://example.com/a"),
  b.goto("https://example.com/b"),
]);
const da = a.extract({ title: "h1" }); // reads page a
const db = b.extract({ title: "h1" }); // reads page b
a.click("#more");                       // any method works on either
```

A single page that re-navigates always stays valid. But a *new* page navigated
sequentially (nothing else in flight) replaces the root page, so any earlier
page goes **stale** — calling a method on it throws `page handle is no longer
valid`:

```js
const a = new Page();
await a.goto("https://example.com/a");
const b = new Page();
await b.goto("https://example.com/b"); // replaces the root; `a` is now stale
a.extract({ title: "h1" });            // throws: page handle is no longer valid
```

Read a parallel batch's pages before your next standalone navigation, and call
`page.close()` to free a page (a popup) you're done with mid-script. The root
page is reclaimed at script end.

## Structured Extraction

Use `page.extract(...)` to read data from the page without writing page-side
JavaScript. This is the preferred bridge from page content into local agent
logic.

```js
const result = page.extract({
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

- `page.extract({ title: "h1" })` returns `{ title: "..." }`.
- `page.extract({ title: "h1", links: [{ selector: "a" }] })` returns an object
  with both fields.
- `page.extract({ links: [{ selector: "a" }] })` returns `{ links: [...] }` — an
  object schema always returns an object, even with a single field.
- `page.extract([{ selector: "a" }])` is shorthand for a single anonymous array
  extraction and returns the array directly.

Every value is a string (trimmed text or a raw attribute) or `null` — parse
numbers in script logic. An array field that matches nothing yields `[]`
without complaint (a page with zero comments is a valid result), but if
*every* field in the schema misses, `page.extract(...)` throws
`no schema selector matched any element` — treat that as "my selectors are
wrong", not "the page is empty".

`page.extract(...)` reads only that page. For list-to-detail scraping — capture
a list, then visit each row for more — capture the list, then loop in the
script: `await page.goto(...)` each row's URL and `extract` the detail. The
local agent context keeps the data across navigations, so the assembly happens
in plain JavaScript. See the [complete example](#complete-example) below.

When passing an object directly to `page.extract(...)`, the runtime serializes
it as the extractor schema. These forms are equivalent:

```js
page.extract({ title: "h1" });
page.extract({ schema: { title: "h1" } });
page.extract('{ "title": "h1" }');
```

The wrapped form accepts only `schema`: the REPL's `save=` option does not
exist in scripts (`page.extract({ schema: ..., save: ... })` is rejected). Keep
results in local variables instead.

## Page JavaScript

`page.evaluate(...)` is the explicit escape hatch into the page's JavaScript
context. Its script string runs where `window` and `document` exist.

```js
const page = new Page();
await page.goto("https://example.com");

const title = page.evaluate("document.title");
console.log(title);
```

Keep the boundary clear:

```js
const selector = "h1";

// Good: local agent logic builds an extract schema.
const data = page.extract({ heading: selector });

// Bad: page evaluate cannot see local agent variables.
page.evaluate("document.querySelector(selector).textContent");
```

Page `evaluate(...)` cannot call `goto`, `extract`, or other agent primitives.
Agent scripts cannot access `document` directly. If you need page DOM data,
prefer `page.extract(...)`; use `page.evaluate(...)` only for page behavior that
extraction cannot express.

`page.waitForScript(...)` also evaluates in the page context, repeatedly, until
the expression is truthy or the timeout expires:

```js
page.waitForScript("document.querySelectorAll('.row').length >= 5");
```

## Interaction Primitives

The action methods operate on the page they're called on. Most take one object
whose fields match the browser tool schema:

```js
const page = new Page();
await page.goto("https://example.com/login");

page.click({ selector: "a.login" });
page.fill({ selector: "input[name='acct']", value: "$LP_HN_USERNAME" });
page.fill({ selector: "input[name='pw']", value: "$LP_HN_PASSWORD" });
page.press({ key: "Enter" });

page.waitForSelector("#logout");

page.hover({ selector: "#menu" });
page.selectOption({ selector: "select[name='country']", value: "FR" });
page.setChecked({ selector: "input[name='terms']", checked: true });
page.setChecked({ selector: "input[name='newsletter']", checked: false });

page.scroll({ y: 600 });
page.scroll();
```

`setChecked` defaults `checked` to `true` when the field is omitted
(`page.setChecked("#chk")` checks the box). `press`'s leading positional is the
optional `selector`, not `key`: a bare `page.press("Enter")` binds `"Enter"` to
`selector` and fails. Press on the focused element with
`page.press({ key: "Enter" })` or `page.press(null, "Enter")`; target an element
with `page.press("#search", "Enter")` or
`page.press({ key: "Enter", selector: "#search" })`.

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

`/save` writes JavaScript by default — making the page once up front, then
calling every recorded tool as a method on it (`goto` awaited, the rest
synchronous):

```js
const page = new Page();
await page.goto("https://example.com");
page.click({ selector: "a.login" });
```

A later `/goto` in the same session records as another `await page.goto(...)` on
the same page, matching the REPL's replace-in-place navigation.

Only replayable browser actions are recorded:

- Recorded: `goto`, `click`, `fill`, `scroll`, `hover`, `press`,
  `selectOption`, `setChecked`, `waitForSelector`, `waitForScript`,
  `waitForState`, `evaluate`, and `extract` — the same set installed as page
  methods.
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
  page.waitForSelector({ selector: "#dashboard", timeout: 1000 });
} catch (err) {
  console.error("dashboard did not appear:", err.message);
  throw err;
}
```

Common failures:

| Error | Meaning |
|-------|---------|
| `ReferenceError: document is not defined` | You tried to use browser DOM APIs in the agent context. Use `page.extract(...)` or `page.evaluate(...)`. |
| `ReferenceError: require is not defined` | Agent scripts are not Node.js scripts. |
| `Page must be called with new` | `Page(...)` was called without `new`. Use `const page = new Page();`. |
| `page is not navigated or has been closed` | A method ran on a fresh `new Page()` (or one already closed). Call `await page.goto(url)` first. |
| `page handle is no longer valid` | The page was used after a later sequential navigation replaced the root page. Read through the current page. |
| `no page loaded - run goto(url) first` | A page-dependent primitive ran before navigation. |
| `invalid arguments` | A primitive received the wrong number or shape of arguments, or a non-JSON-serializable value. |
| `extract: no schema selector matched any element` | Every field in the schema missed. Fix the selectors; an empty page section yields `null`/`[]` per field, not this error. |

## Complete Example

This script opens Hacker News, extracts five stories, visits each comments
page, and prints one JSON object. The looping and object assembly happen in
the local agent script, not in the page.

```js
const HN = "https://news.ycombinator.com";

const page = new Page();
await page.goto(HN);

const { stories } = page.extract({
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

  await page.goto(`${HN}/item?id=${story.id}`);
  const { comments } = page.extract({
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
