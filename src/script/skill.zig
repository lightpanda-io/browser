// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Skill documentation for writing PandaScript agent scripts, assembled
//! from hand-written prose and a primitives reference generated from the
//! tool schemas (`Schema.all()`), so signatures, enums, and defaults
//! can't drift from the code. Consumed by the `/save` system prompt and
//! exported as `SKILL.md` by `zig build skills`.

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Schema = @import("Schema.zig");

pub const name = "pandascript";
pub const description = "Write PandaScript agent scripts (.js) — Lightpanda's replayable browser-automation format, run token-free with `lightpanda agent script.js`.";

/// Semantics summary for the agent's default system prompt, so the agent
/// answers user questions about PandaScript from these rules instead of
/// inventing them. Kept here beside the full skill text ("Mental model"
/// below) so the two stay in sync when the Runtime contract changes.
pub const semantics_note =
    \\- PandaScript (the saved-script language of `/save`): scripts run
    \\  wrapped in an async function, so a script's output is ONLY its
    \\  top-level `return <value>` (objects/arrays printed as JSON) — a bare
    \\  trailing expression is NOT printed. `Page` is the only global:
    \\  `const page = new Page(); await page.goto(url);` then synchronous
    \\  `page.extract({...})`. Only page-side `evaluate` yields the value of
    \\  a bare trailing expression.
;

/// The skill body (no frontmatter). Lazily rendered once, process lifetime.
pub fn text() []const u8 {
    text_once.call();
    return text_buffer.written();
}

/// Frontmatter + body, the on-disk `SKILL.md` shape.
pub fn write(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("---\nname: {s}\ndescription: {s}\n---\n\n", .{ name, description });
    try writer.writeAll(text());
}

var text_buffer: std.Io.Writer.Allocating = undefined;
var text_once = std.once(initText);

/// Panics on failure — the inputs are comptime tool defs, so any render
/// error is a build-time bug.
fn initText() void {
    text_buffer = .init(std.heap.page_allocator);
    render(&text_buffer.writer) catch |err| {
        std.debug.panic("failed to render the {s} skill: {s}", .{ name, @errorName(err) });
    };
}

fn render(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(prose_head ++ "\n\n");
    try writeReference(w);
    try w.writeAll(prose_tail ++ "\n");
}

/// The generated primitives reference: one table row per recorded tool
/// plus an options list surfacing the per-parameter schema descriptions.
fn writeReference(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(table_head ++ "\n");
    for (Schema.all()) |*s| {
        if (!s.tool.isRecorded()) continue;
        try writeRow(w, s);
    }

    try w.writeAll("\nOptions (the trailing `{ … }` object; every option may be omitted):\n\n");
    for (Schema.all()) |*s| {
        if (!s.tool.isRecorded() or s.tool == .extract) continue;
        if (!hasOptions(s)) continue;
        try w.print("- `{s}`:", .{s.tool_name});
        for (s.fields) |f| {
            if (!isOption(s, f.name)) continue;
            try w.print(" `{s}`", .{f.name});
            if (f.description.len > 0) try w.print(" — {s}", .{f.description});
        }
        try w.writeAll("\n");
    }
    try w.writeAll("\n");
}

fn writeRow(w: *std.Io.Writer, s: *const Schema) std.Io.Writer.Error!void {
    try w.writeAll("| `");
    if (s.tool.isAsync()) try w.writeAll("await ");
    try w.print("page.{s}(", .{s.tool_name});
    for (s.positional, 0..) |p, i| {
        const optional = positionalOptional(s, p);
        // A trailing optional positional is bracketed; a leading one
        // (press's selector) renders plain and its note explains `null`.
        if (i > 0) try w.writeAll(if (optional) "[, " else ", ");
        try w.writeAll(p);
        if (i > 0 and optional) try w.writeAll("]");
    }
    // The script form of extract takes the schema as its only argument
    // (`Runtime.extractArgs`); every other tool accepts the options object.
    if (s.tool != .extract and hasOptions(s)) {
        try w.writeAll(if (s.positional.len > 0) "[, { " else "[{ ");
        var i: usize = 0;
        for (s.fields) |f| {
            if (!isOption(s, f.name)) continue;
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(f.name);
            i += 1;
        }
        try w.writeAll(" }]");
    }
    try w.writeAll(")` | ");

    var wrote = false;
    if (s.tool.isAsync()) {
        try w.writeAll("**Async — must be `await`ed.**");
        wrote = true;
    }
    const n = note(s.tool);
    if (n.len > 0) {
        if (wrote) try w.writeAll(" ");
        try w.writeAll(n);
        wrote = true;
    }
    for (s.fields) |f| {
        if (f.enum_values.len == 0 or std.mem.eql(u8, f.name, "backendNodeId")) continue;
        if (wrote) try w.writeAll(" ");
        try w.print("`{s}`: one of", .{f.name});
        for (f.enum_values, 0..) |v, i| {
            try w.print("{s} `\"{s}\"`", .{ if (i == 0) "" else ",", v });
        }
        try w.writeAll(".");
        wrote = true;
    }
    for (s.positional) |p| {
        const f = s.findField(p) orelse continue;
        if (!f.default_true) continue;
        if (wrote) try w.writeAll(" ");
        try w.print("`{s}` defaults to `true`.", .{p});
        wrote = true;
    }
    try w.writeAll(" |\n");
}

/// Non-positional schema fields surfacing in the script signature.
/// `backendNodeId` is ephemeral and has no script form.
fn isOption(s: *const Schema, field_name: []const u8) bool {
    if (std.mem.eql(u8, field_name, "backendNodeId")) return false;
    for (s.positional) |p| {
        if (std.mem.eql(u8, p, field_name)) return false;
    }
    return true;
}

fn hasOptions(s: *const Schema) bool {
    for (s.fields) |f| {
        if (isOption(s, f.name)) return true;
    }
    return false;
}

/// Whether a positional may be omitted in the script form. The schema marks
/// `selector` optional (backendNodeId alternative), but locator tools have
/// no such alternative in scripts, so their selector is effectively required.
fn positionalOptional(s: *const Schema, p: []const u8) bool {
    if (s.findField(p)) |f| {
        if (f.default_true) return true;
    }
    if (std.mem.eql(u8, p, "selector") and s.tool.needsLocator()) return false;
    for (s.required) |r| {
        if (std.mem.eql(u8, r, p)) return false;
    }
    return true;
}

/// Curated per-tool script semantics the JSON schema can't express.
/// Exhaustive so adding or renaming a tool is a compile error until it
/// makes an explicit choice; non-recorded tools have no script form.
fn note(tool: browser_tools.Tool) []const u8 {
    return switch (tool) {
        .goto => "Navigates the page (re-navigating reuses the same object). Waits for `load`. Rejects on navigation failure; a **timeout does NOT reject** (the page may still be usable). Default timeout 10000 ms.",
        .evaluate => "Page-side JS escape hatch; returns text (JSON for objects/arrays).",
        .extract => "The only primitive returning a real JS value (object/array). The schema is its only argument. See schema below.",
        .waitForSelector => "`waitFor*` default timeout 5000 ms.",
        .waitForScript => "Re-evaluates page JS until truthy.",
        .waitForState => "",
        .press => "Selector first! `page.press(\"Enter\")` binds \"Enter\" to `selector` and fails — use `page.press(null, \"Enter\")` or `page.press({ key: \"Enter\" })`.",
        .click, .fill, .scroll, .hover, .selectOption, .setChecked => "",
        .search, .markdown, .html, .links, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => "",
    };
}

const prose_head =
    \\# Writing Lightpanda agent scripts
    \\
    \\Run with:
    \\
    \\```console
    \\./lightpanda agent script.js
    \\```
    \\
    \\## Mental model (get this right first)
    \\
    \\The script runs in its **own V8 context** — neither the page nor Node.js:
    \\
    \\- `Page` is the only global. `new Page()` makes a page and `await page.goto(url)` navigates it; every other primitive is a **method on that page**: `const page = new Page(); await page.goto(url); page.extract({...}); page.click(sel);`.
    \\- No `window`, `document`, DOM, `localStorage` — read pages with `page.extract(...)`, run page-side JS only via `page.evaluate("...")`.
    \\- No `require`, `process`, `fs`, npm. Standard ECMAScript built-ins only (`JSON`, `Map`, template literals, …).
    \\- `page.goto(...)` is **async — always `await` it**. Page methods are **synchronous**: `const data = page.extract({...})`, never `await page.extract(...)`. The script body runs as an async function, so top-level `await` is allowed.
    \\- **Re-navigating reuses the same page**: `await page.goto(url2)` keeps `page` valid and points it at the new URL, discarding the old page — read it before navigating away. Independent URLs don't share a page: make a `new Page()` for each and load them in parallel (fan-out, best practice 2).
    \\- Page `evaluate("...")` cannot see script variables — interpolate values into the string. Script code cannot see page variables.
    \\- Variables persist across navigations within one run, so cross-page aggregation is plain JS.
    \\- **`return <value>` is the script's output**, printed automatically (objects/arrays as JSON). End with `return page.extract({...});` or `return results;`. A bare trailing expression is NOT printed; neither is `console.log(JSON.stringify(...))`.
    \\
    \\## Primitives
    \\
    \\`Page` is the only global; `new Page()` makes a page and everything else is a method on it.
;

const table_head =
    \\| Call | Notes |
    \\|------|-------|
    \\| `new Page()` | Makes a page object. No navigation yet — call `page.goto(url)` before any other method. Make several to navigate in parallel (fan-out, best practice 2). |
    \\| `page.close()` | Marks the page done; later method calls on it error. The page is otherwise reclaimed at script end. |
;

const prose_tail =
    \\Calling convention: leading positionals + optional trailing options object, or one object with everything (`page.waitForSelector("#row", { timeout: 2000 })` ≡ `page.waitForSelector({ selector: "#row", timeout: 2000 })`). A bare option positional (`page.waitForSelector("#row", 2000)`) and a field passed both ways are `invalid arguments`. `null` skips a positional. Arguments must be JSON-serializable.
    \\
    \\CSS selectors only — `backendNodeId`s don't exist here. Standard CSS only: no jQuery `:contains()` or Playwright `:has-text()`.
    \\
    \\## extract schema
    \\
    \\Keys = output field names; values pick what to lift (not a JSON Schema):
    \\
    \\```js
    \\const { stories } = page.extract({
    \\  stories: [{
    \\    selector: "tr.athing",          // one record per match
    \\    limit: 5,
    \\    fields: {                        // resolved relative to each match
    \\      title: ".titleline > a",      // first match's text (null if missing)
    \\      url: { selector: ".titleline > a", attr: "href" },
    \\      text: ""                       // "" = the matched element's own text
    \\    }
    \\  }]
    \\});
    \\```
    \\
    \\- `"sel"` → first match's text; `["sel"]` → all matches' text; `{ selector, attr }` / `[{ selector, attr }]` → attribute(s); `limit: N` caps any array form.
    \\- Every value is a string or null — parse numbers in script logic.
    \\- Empty arrays are valid results; if **every** field misses, extract throws ("no schema selector matched any element") → your selectors are wrong, not the page empty.
    \\- An object schema always returns an object (destructure it); a bare array schema returns the array directly.
    \\- No `save:` option in scripts — keep results in variables.
    \\
    \\## Best practices
    \\
    \\1. **Navigate, settle, read.** After `await page.goto` on a dynamic page (feeds, search results, comment threads), call `page.waitForState("networkidle")` or `page.waitForSelector(...)` before extracting. Most static pages are complete at `load` — don't wait blindly.
    \\2. **List-to-detail — fan out independent pages.** Extract the list, then open one page per item and start every navigation together so the detail pages load in parallel instead of one-after-another:
    \\   ```js
    \\   const list = new Page();
    \\   await list.goto(listUrl);
    \\   const { items } = list.extract({ items: [{ selector: "a.row", fields: { url: { attr: "href" } } }] });
    \\
    \\   const pages = items.map(() => new Page());
    \\   await Promise.all(pages.map((p, i) => p.goto(items[i].url)));   // all in flight at once
    \\   return pages.map((p, i) => ({ ...items[i], ...p.extract({ /* schema */ }) }));
    \\   ```
    \\   - Concurrency is bounded by the HTTP connection pool: 40 total (`--http-max-concurrent`) and 6 per host (`--http-max-host-open`, the browser default — raising it much higher risks overwhelming the target server). Extra navigations queue rather than fail, so a same-site fan-out loads ~6 pages at a time. For long lists, fan out in batches and `page.close()` each page once read so its memory is reclaimed.
    \\   - `Promise.all` rejects the whole batch if any `goto` *fails* (a timeout does not reject); use `Promise.allSettled` when partial results are fine.
    \\   - Walk **serially** on one page (`for (const it of items) { await page.goto(it.url); … }`) only when the steps depend on each other — each page decides the next URL, or they share login/session state.
    \\3. **`evaluate` is a last resort, not a reading tool.** A `querySelectorAll`-and-parse `page.evaluate` block is always wrong: lift the raw strings with `page.extract`, then trim/split/parse them in top-level JS. Reserve `page.evaluate` for behavior that must run inside the page and no builtin covers — and remember its state dies on every navigation/reload, while script variables persist.
    \\4. **Credentials via `$LP_*` placeholders** in any string argument (`page.fill("#pw", "$LP_HN_PASSWORD")`). Never inline a real secret; placeholders resolve inside the Lightpanda process.
    \\5. **Unique selectors.** Disambiguate with attributes/position: `input[type="submit"][value="login"]`, not `input[type="submit"]`.
    \\6. **Let failures fail.** Primitives throw on error and stop the script — only `try/catch` where you have a real fallback (e.g. optional cookie banner: `try { page.click("#accept") } catch {}`).
    \\7. **End with `return <result>`.** `console.log` is for debug output only and doesn't JSON-format objects.
    \\8. Modern, readable JS: `const`/`let`, `for (const x of xs)`, template literals, destructuring, 2-space indent.
    \\9. **Comment the intent of each block.** Put a one-line `//` comment above each logical step describing what it accomplishes toward the goal (not restating the call). One comment per block, not per line — skip self-evident lines:
    \\   ```js
    \\   // Load the Hacker News front page
    \\   const page = new Page();
    \\   await page.goto("https://news.ycombinator.com");
    \\
    \\   // Pull the top 5 stories (title + link)
    \\   const { stories } = page.extract({ stories: [{ selector: "tr.athing", limit: 5, fields: { title: ".titleline > a", url: { selector: ".titleline > a", attr: "href" } } }] });
    \\
    \\   // Open each story page in parallel and read its text
    \\   const pages = stories.map(() => new Page());
    \\   await Promise.all(pages.map((p, i) => p.goto(stories[i].url)));
    \\   ```
    \\
    \\## Common errors
    \\
    \\| Error | Cause / fix |
    \\|-------|-------------|
    \\| `extract is not defined` (or click/fill/…) | These are methods on the page object, not globals → `const page = new Page(); await page.goto(url); page.extract(...)` |
    \\| `Page must be called with new` | `Page(...)` called without `new` → `const page = new Page();` |
    \\| `page is not navigated or has been closed` | A method on a fresh `new Page()` (or a closed page) → `await page.goto(url)` first |
    \\| `page handle is no longer valid` | Used a page after a later `goto` on the **same** page replaced it → read it before navigating away. Sibling pages from other `new Page()` calls stay valid. |
    \\| `document is not defined` | DOM API in script context → use `page.extract` or `page.evaluate` |
    \\| `require is not defined` | Not Node.js |
    \\| `no page loaded - run page.goto(url) first` | Page method before navigation |
    \\| `invalid arguments` | Wrong arity/shape, non-JSON value, or a field set both positionally and in options |
    \\| `extract: no schema selector matched any element` | All schema fields missed → fix selectors |
    \\| `press` fails with one string arg | Selector-first: use `page.press(null, "Enter")` or `page.press({ key: "Enter" })` |
;

const testing = @import("../testing.zig");

test "skill: every recorded tool is documented, no non-recorded one is" {
    const body = text();
    inline for (comptime std.meta.tags(browser_tools.Tool)) |tool| {
        const call = "page." ++ @tagName(tool) ++ "(";
        const documented = std.mem.indexOf(u8, body, call) != null;
        try testing.expect(documented == tool.isRecorded());
    }
    try testing.expect(std.mem.indexOf(u8, body, "await page.goto(") != null);
}

test "skill: golden fragments track the schemas" {
    const body = text();
    // waitForState's enum list tracks Config.WaitUntil.
    inline for (comptime std.meta.tags(lp.Config.WaitUntil)) |state| {
        try testing.expect(std.mem.indexOf(u8, body, "\"" ++ @tagName(state) ++ "\"") != null);
    }
    try testing.expect(std.mem.indexOf(u8, body, "`checked` defaults to `true`.") != null);
    // extract's script form takes the schema as its only argument.
    try testing.expect(std.mem.indexOf(u8, body, "page.extract(schema)") != null);
    try testing.expect(std.mem.indexOf(u8, body, "page.extract(schema[, ") == null);
    try testing.expect(std.mem.indexOf(u8, body, "{ url, timeout, save }") != null);
    // backendNodeId has no script form.
    try testing.expect(std.mem.indexOf(u8, body, "backendNodeId }") == null);
}

test "skill: write emits frontmatter" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(&aw.writer);
    try testing.expect(std.mem.startsWith(u8, aw.written(), "---\nname: pandascript\ndescription: "));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\n---\n\n# Writing Lightpanda agent scripts\n") != null);
}
