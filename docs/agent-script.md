# Agent JavaScript scripts

`lightpanda agent <script.js>` runs a JavaScript file that drives a
Lightpanda browser session through a small object-oriented API. The format is
intentionally plain JavaScript: use normal variables, functions, loops,
objects, arrays, `JSON.parse`, `JSON.stringify`, and other standard ECMAScript
built-ins.

```console
./lightpanda agent session.js
```

The interactive REPL still uses slash commands. `/save` writes the recorded
browser actions as JavaScript calls so the saved file can be replayed without
an LLM.

## Runtime Environment

Agent scripts run in their own V8 context. That context is separate from the
web page's JavaScript context.

- `Page` is the only global. `new Page()` makes a page object and
  `await page.goto(url)` navigates it; every other primitive is a **method on
  that page**: `const page = new Page(); await page.goto(url);
  page.extract({...}); page.click(sel);`.
- It is not the browser page environment. There is no `window`, `document`,
  DOM, `localStorage`, `navigator`, or page global state in the agent script.
  Read page data with `page.extract(...)`, or explicitly run page JavaScript
  with `page.evaluate(...)` when that is the right tool.
- It is not Node.js. There is no `require`, `process`, `fs`, `path`, npm
  package loading, command-line argument API, or Node network/filesystem API.
- Page scripts cannot see agent variables or Lightpanda primitives. Agent
  scripts cannot directly see page variables.
- The `page.evaluate(...)` method runs JavaScript in the page context,
  distinct from the agent context's own native `eval`.
- Agent variables persist for the lifetime of one script run, across
  navigations and primitive calls. A later `lightpanda agent script.js` run
  starts with a fresh agent context.
- `page.goto(...)` is **async — always `await` it**. Every other page method
  is **synchronous**: write `const data = page.extract({...})`, never
  `await page.extract(...)`. The script body runs as an async function, so
  top-level `await` is allowed.
- **Re-navigating reuses the same page.** `await page.goto(url2)` keeps `page`
  valid and points it at the new URL. Work through one page at a time and read
  it before navigating away.
- Tool failures throw JavaScript `Error` exceptions and stop execution unless
  you catch them.
- **`return <value>` is the script's output**, printed automatically (objects
  and arrays as JSON; other values coerced). End a script with the value you
  want as output, e.g. `return page.extract({ ... });` or `return results;`. A
  bare trailing expression is NOT printed, and neither is
  `console.log(JSON.stringify(...))`.

The agent context includes a small `console` object:

```js
console.log("printed to stdout");
console.info("printed to stdout");
console.debug("printed to stdout");
console.warn("printed to stderr");
console.error("printed to stderr");
```

## Values And Return Types

Most page methods return the browser tool's result text as a JavaScript
string. `page.extract(...)` is the exception: it returns extracted data as a
normal JavaScript value, so local script logic can use it directly. The result
mirrors your schema — an object schema returns an object keyed by your fields
(even with a single field), and a bare array schema returns an array:

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

## The Page object

`Page` is the only global. `new Page()` makes a page object; everything else is
a method on it. Call `Page(...)` without `new` and you get
`Page must be called with new`.

| Method | Arguments | Runs in |
|--------|-----------|---------|
| `new Page()` | — | Makes a page object. No navigation yet — call `page.goto(url)` before any other method. |
| `page.goto` | `goto(url[, { timeout }])` | **Async — must be `await`ed.** Navigates the page (re-navigating reuses the same object). |
| `page.close` | `close()` | Marks the page done; later method calls on it error. The page is otherwise reclaimed at script end. |
| `page.extract` | `extract(schema)` or `extract({ schema })` | Browser page via extractor; returns a JS object or array |
| `page.evaluate` | `evaluate(script[, { url, timeout, save }])` | Browser page JS context |
| `page.click` | `click(selector)` or `click({ selector })` | Browser page |
| `page.fill` | `fill(selector, value)` or `fill({ selector, value })` | Browser page |
| `page.scroll` | `scroll()` or `scroll({ x, y })` | Browser page |
| `page.waitForSelector` | `waitForSelector(selector[, { timeout }])` | Browser page |
| `page.waitForScript` | `waitForScript(script[, { timeout }])` | Browser page JS context |
| `page.waitForState` | `waitForState(state[, { timeout }])` | Browser page |
| `page.hover` | `hover(selector)` or `hover({ selector })` | Browser page |
| `page.press` | `press(selector, key)` or `press({ key[, selector] })` | Browser page |
| `page.selectOption` | `selectOption(selector, value)` or `selectOption({ selector, value })` | Browser page |
| `page.setChecked` | `setChecked(selector[, checked])` or `setChecked({ selector, checked })` | Browser page |

`page.goto` returns at the `load` event (a fast snapshot). When a page's
content is still loading (rendered by post-load JS), call
`page.waitForState("networkidle")` before reading. `waitForState`'s `state`
accepts `"load"`, `"domcontentloaded"`, `"networkalmostidle"`,
`"networkidle"`, `"done"`. `goto`'s `timeout` defaults to 10000 ms; the
`waitFor*` timeouts default to 5000 ms.

The `[, { … }]` is an optional trailing options object: leading arguments are
positional (`page.waitForSelector("#row", { timeout: 2000 })`), and the
options ride in a final object. Passing a single object with everything
(`page.waitForSelector({ selector: "#row", timeout: 2000 })`) is equivalent —
that's the shape `/save` records into saved scripts. An option can't be a bare
positional, though: `page.waitForSelector("#row", 2000)` is an error. A `null`
positional omits that field (`page.press(null, "Enter")` presses on the
focused element), and setting the same field positionally and in the options
object (`page.goto(url, { url: ... })`) is an `invalid arguments` error.

Page methods address elements by CSS selector only. The tools that hand out
`backendNodeId`s (`tree`, `findElement`, `nodeDetails`) aren't installed in
the script context, and a raw node ID wouldn't survive replay anyway. When
you're exploring in the REPL and have a `backendNodeId` — e.g. the leading
number on a `/tree` line, or a `/findElement` hit — run `/nodeDetails
backendNodeId=<id>` to get a durable CSS `selector`, then paste that into your
script.

## Navigation

Use `page.goto(...)` to open a page. It is the only async method, so always
`await` it:

```js
const page = new Page();
await page.goto("https://example.com");

await page.goto({
  url: "https://example.com/app",
  timeout: 15000
});
```

Re-navigating reuses the same page object: a later `await page.goto(url2)`
keeps `page` valid and points it at the new URL. Read a page before navigating
away from it.

The call returns a status string and throws if navigation fails. A timeout
does **not** throw: the call returns `"Navigation started but the page did not
finish loading before the timeout."` and the page stays in whatever state it
reached. Check the return value — or follow with `page.waitForState(...)` /
`page.waitForSelector(...)` — when completeness matters.

## Structured Extraction

Use `page.extract(...)` to read data from the current page without writing
page-side JavaScript. This is the preferred bridge from page content into
local agent logic.

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
- `page.extract({ title: "h1", links: [{ selector: "a" }] })` returns an
  object with both fields.
- `page.extract({ links: [{ selector: "a" }] })` returns `{ links: [...] }` —
  an object schema always returns an object, even with a single field.
- `page.extract([{ selector: "a" }])` is shorthand for a single anonymous
  array extraction and returns the array directly.

Every value is a string (trimmed text or a raw attribute) or `null` — parse
numbers in script logic. An array field that matches nothing yields `[]`
without complaint (a page with zero comments is a valid result), but if
*every* field in the schema misses, `page.extract(...)` throws
`no schema selector matched any element` — treat that as "my selectors are
wrong", not "the page is empty".

`page.extract(...)` reads only the current page. For list-to-detail scraping —
capture a list, then visit each row for more — capture the list, then loop in
the script: `await page.goto` each row's URL and `page.extract` the detail,
reading each detail page before navigating to the next. The local agent
context keeps the data across navigations, so the assembly happens in plain
JavaScript. See the [complete example](#complete-example) below.

When passing an object directly to `page.extract(...)`, the runtime serializes
it as the extractor schema. These forms are equivalent:

```js
page.extract({ title: "h1" });
page.extract({ schema: { title: "h1" } });
page.extract('{ "title": "h1" }');
```

The wrapped form accepts only `schema`: the REPL's `save=` option does not
exist in scripts (`page.extract({ schema: ..., save: ... })` is rejected).
Keep results in local variables instead.

Use local variables to keep extracted data available to later script logic:

```js
const head = page.extract({ title: "title" });
```

## Page JavaScript

`page.evaluate(...)` is the explicit escape hatch into the current page's
JavaScript context. Its script string runs where `window` and `document`
exist.

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

`page.evaluate(...)` cannot call `goto`, `extract`, or other agent primitives.
Agent scripts cannot access `document` directly. If you need page DOM data,
prefer `page.extract(...)`; use `page.evaluate(...)` only for page behavior
that extraction cannot express, and remember its state dies on every
navigation/reload, while script variables persist.

`page.waitForScript(...)` also evaluates in the page context, repeatedly,
until the expression is truthy or the timeout expires:

```js
page.waitForScript("document.querySelectorAll('.row').length >= 5");
```

## Interaction Primitives

The action methods operate on the current page. Most take one object whose
fields match the browser tool schema:

```js
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

`page.setChecked` defaults `checked` to `true` when the field is omitted
(`page.setChecked("#chk")` checks the box). `page.press`'s leading positional
is the optional `selector`, not `key`: a bare `page.press("Enter")` binds
`"Enter"` to `selector` and fails. Press on the focused element with
`page.press({ key: "Enter" })` or `page.press(null, "Enter")`; target an
element with `page.press("#search", "Enter")` or
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

`/save` writes JavaScript by default:

```js
const page = new Page();
await page.goto("https://example.com");
page.click({ selector: "a.login" });
```

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
| `extract is not defined` (or `click`/`fill`/…) | These are methods on the page object, not globals. Use `const page = new Page(); await page.goto(url); page.extract(...)`. |
| `Page must be called with new` | `Page(...)` was called without `new`. Use `const page = new Page();`. |
| `page is not navigated or has been closed; call page.goto(url) first` | A method ran on a fresh `new Page()` (or a closed page). `await page.goto(url)` first. |
| `page handle is no longer valid` | A page was used after a later `goto` replaced it. Read a page before navigating away. |
| `ReferenceError: document is not defined` | You tried to use browser DOM APIs in the agent context. Use `page.extract(...)` or `page.evaluate(...)`. |
| `ReferenceError: require is not defined` | Agent scripts are not Node.js scripts. |
| `no page loaded - run page.goto(url) first` | A page method ran before navigation. |
| `invalid arguments` | A method received the wrong number or shape of arguments, or a non-JSON-serializable value. |
| `extract: no schema selector matched any element` | Every field in the schema missed. Fix the selectors; an empty page section yields `null`/`[]` per field, not this error. |

## Complete Example

This script opens Hacker News, extracts five stories, visits each comments
page, and prints one JSON object. A single reusable `page` walks the list
sequentially — read each detail page before navigating to the next. The
looping and object assembly happen in the local agent script, not in the page.

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
