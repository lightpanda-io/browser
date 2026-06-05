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
- The installed primitives are synchronous and blocking. Do not write an
  `async`/`await` automation contract around them.
- Tool failures throw JavaScript `Error` exceptions and stop execution unless
  you catch them.
- The script's completion value — its last top-level expression — is printed
  automatically (objects and arrays as JSON; other values coerced). End a
  script with the bare expression you want as output, e.g. a final
  `extract({ ... });` or `results;`. `console.log(...)` is for extra or debug
  output and does not JSON-format objects.

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
goto("https://news.ycombinator.com/");

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

data; // printed automatically as JSON
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
| `goto` | `goto(url)` or `goto({ url, timeout, waitUntil })` | Browser session |
| `extract` | `extract(schema)` or `extract({ schema })` | Browser page via extractor; returns a JS object or array |
| `evaluate` | `evaluate(script)` or `evaluate({ script, url, timeout, waitUntil, save })` | Browser page JS context |
| `click` | `click({ selector })` or `click({ backendNodeId })` | Browser page |
| `fill` | `fill({ selector, value })` or `fill({ backendNodeId, value })` | Browser page |
| `scroll` | `scroll()` or `scroll({ x, y, backendNodeId })` | Browser page |
| `waitForSelector` | `waitForSelector(selector)` or `waitForSelector({ selector, timeout })` | Browser page |
| `waitForScript` | `waitForScript(script)` or `waitForScript({ script, timeout })` | Browser page JS context |
| `hover` | `hover({ selector })` or `hover({ backendNodeId })` | Browser page |
| `press` | `press(key)` or `press({ key, selector, backendNodeId })` | Browser page |
| `selectOption` | `selectOption({ selector, value })` or `selectOption({ backendNodeId, value })` | Browser page |
| `setChecked` | `setChecked({ selector, checked })` or `setChecked({ backendNodeId, checked })` | Browser page |

`waitUntil` accepts `"load"`, `"domcontentloaded"`, `"networkidle"`, or
`"done"`.

Prefer CSS selectors in saved scripts. `backendNodeId` values are tied to the
current DOM snapshot and are not stable after navigation or DOM mutation.

## Navigation

Use `goto(...)` to open a page:

```js
goto("https://example.com");

goto({
  url: "https://example.com/app",
  timeout: 15000,
  waitUntil: "domcontentloaded"
});
```

The call returns a status string. It throws if navigation fails or times out.

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

Use local variables to keep extracted data available to later script logic:

```js
const page = extract({ title: "title" });
```

## Page JavaScript

`evaluate(...)` is the explicit escape hatch into the current page's JavaScript
context. Its script string runs where `window` and `document` exist.

```js
goto("https://example.com");

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
press("Enter");

waitForSelector("#logout");

hover({ selector: "#menu" });
selectOption({ selector: "select[name='country']", value: "FR" });
setChecked({ selector: "input[name='terms']", checked: true });
setChecked({ selector: "input[name='newsletter']", checked: false });

scroll({ y: 600 });
scroll();
```

`setChecked` defaults `checked` to `true` when the field is omitted.
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
goto("https://example.com");
click({ selector: "a.login" });
```

Only replayable browser actions are recorded:

- Recorded: `goto`, `click`, `fill`, `scroll`, `hover`, `press`,
  `selectOption`, `setChecked`, `waitForSelector`, `waitForScript`, `evaluate`,
  and `extract`.
- Not recorded: read-only exploration tools such as `tree`, `markdown`, `html`,
  `links`, `findElement`, `consoleLogs`, `getUrl`, `getCookies`, and `getEnv`.
- Natural-language prompts and recording comments are written as `//` comments.

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

## Complete Example

This script opens Hacker News, extracts five stories, visits each comments
page, and prints one JSON object. The looping and object assembly happen in
the local agent script, not in the page.

```js
const HN = "https://news.ycombinator.com";

goto(HN);

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

  goto(`${HN}/item?id=${story.id}`);
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

stories; // printed automatically as JSON
```
