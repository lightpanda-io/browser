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

//! What each tool tells a model about itself: its description, its one-line
//! summary and its JSON input schema. Tool identity — the `Tool` tag and the
//! predicates over it — stays in tools.zig; this file is only the strings.

const std = @import("std");
const lp = @import("../../lightpanda.zig");
const zenai = @import("zenai");

const tools = @import("../tools.zig");
const Tool = tools.Tool;
const minify = tools.minify;
const cascade_prose = @import("search.zig").cascade_prose;
const inline_image_max_width = tools.inline_image_max_width;
const inline_image_max_height = tools.inline_image_max_height;

/// Per-tool LLM-facing metadata. Tool identity (name + predicates) lives
/// on the enclosing `Tool` enum; this struct just carries the strings.
const url_params_schema = minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "url": { "type": "string", "description": "Optional URL to navigate to before processing. An empty string is treated as omitted." },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." }
    \\  }
    \\}
);

pub const Definition = struct {
    description: []const u8,
    /// Listing-only; the long `description` feeds MCP and `/help <name>`.
    summary: []const u8,
    input_schema: []const u8,
};

/// Source of truth for tool ↔ metadata. The exhaustive switch makes
/// adding a new `Tool` tag a compile error until its description and
/// JSON schema exist. `tool_defs` (below) materializes the array form
/// for callers that iterate (MCP `tools/list`, schema build).
pub fn of(tool: Tool) Definition {
    return switch (tool) {
        .goto => .{
            .description = "Navigate the current page to a URL. Returns the HTTP status once `waitUntil` fires (default `load`), or a timeout notice; a 4xx or 5xx means the page you got is an error page, not the content — check it before reading on; content rendered by post-load JavaScript may not be there yet (see `waitForState`). The page stays loaded for later reads and actions. To navigate and read in one call, pass `url` to `markdown`, `tree` or `html` instead; use `goto` when the next step is an action or `extract`.",
            .summary = "Open a URL and keep the page in memory",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string", "description": "The URL to navigate to, must be a valid URL." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
                \\    "waitUntil": { "type": "string", "enum":
            ++ lp.Config.tagJsonArray(lp.Config.WaitUntil) ++
                \\, "description": "Event that completes the navigation. Defaults to 'load'. Prefer 'domcontentloaded' followed by waitForSelector on pages whose late scripts (ads) hold 'load' back. Avoid 'done' (full quiescence): on pages with constant background activity it is the slowest choice and can run to the timeout." }
                \\  },
                \\  "required": ["url"]
                \\}
            ),
        },
        .search => .{
            .description = "Run a web search and return results as markdown: a numbered list of {title, url, snippet}. Search " ++ cascade_prose ++ ". Prefer this over goto-ing google.com/search directly (Google blocks the browser on User-Agent/TLS). The browser does not navigate — to open a result, use `goto` with its URL.",
            .summary = "Web search, results as markdown",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "query": { "type": "string", "description": "The search query." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." }
                \\  },
                \\  "required": ["query"]
                \\}
            ),
        },
        .markdown => .{
            .description = "Render the page (or a subtree) as markdown. Scope with `selector` or `backendNodeId` to read just the relevant region — full-page markdown is the last resort. Use `maxBytes` to cap long pages.",
            .summary = "Render the page or a subtree as markdown",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "Optional CSS selector. Render markdown for just that element's subtree." },
                \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID. Render markdown for just that node's subtree. 0 is treated as omitted." },
                \\    "maxBytes": { "type": "integer", "description": "Optional soft cap on output size in bytes. Content is truncated at a UTF-8 boundary and a short '[truncated]' marker is appended past the cap." },
                \\    "strip": { "type": "object", "description": "Optional. Omit element groups from the output; same groups as the html tool's strip. `shell` (page chrome by markup) and `clutter` (keep only the main content, in the manner of reader modes) are the ones that matter for reading; `ui` also drops images.", "properties": { "js": { "type": "boolean" }, "css": { "type": "boolean" }, "ui": { "type": "boolean" }, "invisible": { "type": "boolean" }, "shell": { "type": "boolean" }, "clutter": { "type": "boolean" } } },
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before rendering. An empty string is treated as omitted." },
                \\    "alternate": { "type": "boolean", "description": "Optional. When the page links a markdown version of itself (<link rel=\"alternate\" type=\"text/markdown\">), return that file instead of converting the page. It is the author's file and can differ from the rendered page; the output then starts with a comment naming its URL, which maxBytes does not count. Falls back to the page when there is no such link, the page itself failed to load (HTTP error status or bot challenge), or the alternate does not load as markdown within what is left of the timeout. Cannot be combined with selector or backendNodeId. Defaults to false." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." }
                \\  }
                \\}
            ),
        },
        .html => .{
            .description = "Raw HTML for the document or, with `selector`/`backendNodeId`, a single node's outerHTML. Verbose; use only when you need attributes that markdown discards.",
            .summary = "Raw HTML of the page or a node",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "Optional CSS selector. When set, dump only that element's outerHTML." },
                \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID. When set, dump only that node's outerHTML. 0 is treated as omitted." },
                \\    "maxBytes": { "type": "integer", "description": "Optional soft cap on output size in bytes. Content is truncated at a UTF-8 boundary and a short '[truncated]' marker is appended past the cap." },
                \\    "strip": { "type": "object", "description": "Optional. Omit element groups from the output: `js` (script, noscript, script preloads), `css` (style, stylesheet links), `ui` (css plus img, picture, video, audio, svg, canvas, iframe), `invisible` (elements an author rule or inline style sets to display:none), `shell` (nav, aside, dialog, page-level header/footer and the matching landmark roles; skipped when that would drop most of the text), `clutter` (keep only the main content, in the manner of reader modes; includes `shell` and `invisible`, and falls back to `shell` when it finds too little). {\"js\":true,\"css\":true} keeps a page dump small.", "properties": { "js": { "type": "boolean" }, "css": { "type": "boolean" }, "ui": { "type": "boolean" }, "invisible": { "type": "boolean" }, "shell": { "type": "boolean" }, "clutter": { "type": "boolean" } } },
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before dumping. An empty string is treated as omitted." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." }
                \\  }
                \\}
            ),
        },
        .screenshot => .{
            .description = std.fmt.comptimePrint("Render the page, or one node, as a PNG: the text layout Lightpanda computes, not a pixel-accurate browser rendering (no images, fonts or CSS colours). With `path`, writes the file at full size and returns its location; without it, returns the image inline where the client can display one, at most {d}px wide and {d}px tall. Use it to see spatial layout; read content with `markdown`/`tree`.", .{ inline_image_max_width, inline_image_max_height }),
            .summary = "Screenshot of the page or a node",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "path": { "type": "string", "description": "Optional relative path (no '..' segments) to write the PNG to. Created or overwritten. Without it the image is returned inline, which needs a client that can display images." },
                \\    "selector": { "type": "string", "description": "Optional CSS selector. When set, render only that element." },
                \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID. When set, render only that node. 0 is treated as omitted." },
                \\    "fullPage": { "type": "boolean", "description": "Render the whole content height instead of one viewport. Defaults to false." },
                \\    "strip": { "type": "object", "description": "Optional. Omit element groups from the render; same groups as the html tool's strip (`js`, `css`, `ui`, `invisible`, `shell`, `clutter`).", "properties": { "js": { "type": "boolean" }, "css": { "type": "boolean" }, "ui": { "type": "boolean" }, "invisible": { "type": "boolean" }, "shell": { "type": "boolean" }, "clutter": { "type": "boolean" } } },
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before rendering. An empty string is treated as omitted." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." }
                \\  }
                \\}
            ),
        },
        .links => .{
            .description = "Extract the visible links in the opened page as JSON objects with `text` (anchor text, falling back to aria-label/title/image alt), `href` (resolved URL), and `backendNodeId` (pass to click/nodeDetails). One entry per href; hidden links are omitted. If a url is provided, it navigates to that url first.",
            .summary = "List all links on the page",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "limit": { "type": "integer", "description": "Optional. Return at most this many links, in document order." },
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before processing. An empty string is treated as omitted." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." }
                \\  }
                \\}
            ),
        },
        .evaluate => .{
            .description = "Evaluate JavaScript in the current page context — an escape hatch for page-side logic the dedicated tools can't express; prefer `extract` for data and click/fill/etc. for actions. It runs in the page, so it cannot see the agent script's variables or builtins — interpolate any value into the `script` string. A bare trailing expression yields its value; top-level `await` and `return` are supported (the body then runs as an async function, so use `return` to produce a value). Objects and arrays return as JSON, so no `JSON.stringify` is needed. If a url is provided, it navigates there first. The `globalThis.lp` object exposes a Session-scoped bridge store: values written via `lp.foo = ...` auto-sync at end of evaluate, surviving navigation; values previously set via `/extract save=` or `/evaluate save=` appear as `lp.<name>`.",
            .summary = "Run JavaScript in the page",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "script": { "type": "string", "description": "JavaScript run in the page context. A bare trailing expression, or `return` with top-level `await`, is the result." },
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before evaluating. An empty string is treated as omitted." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
                \\    "save": { "type": "string", "description": "Optional bridge-store key. The evaluate's return value is stored under this name and re-exposed as `lp.<name>` to subsequent evaluates. Objects, arrays, and strings are serialized automatically — no JSON.stringify needed." }
                \\  },
                \\  "required": ["script"]
                \\}
            ),
        },
        .extract => .{
            .description =
            \\Extract structured data from the current page (navigate first). `schema` is a JSON object (passed as a string) mapping output field names to CSS-selector specs. It is NOT a JSON Schema — no "type"/"properties" wrappers; the keys ARE your output fields. Value shapes:
            \\```text
            \\"<sel>"                                → first match's text (trimmed; null if no match)
            \\["<sel>"]                              → every match's text (string[])
            \\{"selector":"<sel>","attr":"<name>"}   → first match's attribute value (href/src resolved to absolute URLs)
            \\[{"selector":"<sel>","attr":"<name>"}] → every match's attribute (string[])
            \\[{"selector":"<sel>","fields":{…}}]    → one object per match; field selectors resolve relative to that match and accept any shape above ("" = the match's own text; nest arrays for per-item sub-lists)
            \\```
            \\Add "limit": N inside any array's object spec to cap matches.
            \\Every extracted value is a string or null — parse numbers downstream. An empty array is a valid result, but if ALL top-level keys miss, the call errors: inspect the page (tree/markdown) and retry with corrected selectors.
            \\Finish data tasks with extract — it is the only read recorded as a replayable `extract(...)` script call; answers lifted from `markdown` text in chat are not.
            \\
            \\Examples (schema → result):
            \\```text
            \\{"karma": "#karma"} → {"karma":"42"}
            \\{"items": [".story .title"]} → {"items":["Title 1","Title 2"]}
            \\{"top3": [{"selector":".story .title","limit":3}]} → {"top3":["A","B","C"]}
            \\{"links": [{"selector":"a.title","attr":"href"}]} → {"links":["https://site/a","https://site/b"]}
            \\{"stories": [{"selector":".athing","fields":{"title":".titleline","rank":".rank"}}]} → {"stories":[{"title":"Foo","rank":"1"}]}
            \\```
            ,
            .summary = "Extract structured data via a CSS-selector schema",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "schema": { "type": "string", "description": "Extraction schema as a string: a JSON object literal mapping output field names to CSS-selector specs (see tool description). Not a JSON Schema." },
                \\    "save": { "type": "string", "description": "Optional bridge-store key. The extracted JSON is stored under this name and exposed as `lp.<name>` in subsequent /evaluate calls." }
                \\  },
                \\  "required": ["schema"]
                \\}
            ),
        },
        .classify => .{
            .description = "Classify the page or an element subtree using TypeSafe System One (Jev). `questions` is a JSON array of categories (returns the one that fits), or a JSON object of questions keyed by the name each answer comes back under: `true` for a preset (" ++ tools.jev.Preset.names ++ "; an empty object `{}` asks all of them), a string for a yes/no question (returns its probability), `{question, options}` for a choice, or `{question, levels}` for a score on 2-10 levels ordered low to high (returns the `score` between level indices, the nearest `level`, and per-level `probabilities`). A missing answer is null.",
            .summary = "Classify page state using semantic questions or presets",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "questions": { "type": "string", "description": "JSON string: array of categories, or object of questions (`{}` for every preset)" },
                \\    "selector": { "type": "string", "description": "Optional CSS selector to classify a specific element subtree instead of the full page" },
                \\    "presets": { "type": "boolean", "description": "Also ask every preset in the same call, each answered under its own name beside the questions. Needs the object form." }
                \\  },
                \\  "required": ["questions"]
                \\}
            ),
        },
        .acceptCookies => .{
            .description = "Dismiss the cookie consent banner on the current page: the browser offers the banner's own controls to TypeSafe System One (Jev), clicks the one it picks, and re-reads the page to check the banner went. Returns JSON — `dismissed` is what was clicked, `verified` whether the page agreed afterwards, `selectors` the controls clicked in order, and `reason` why nothing happened when nothing did. A click that leaves a banner up (a confirmation, say) is followed by one more pick. A page with nothing to click costs no model call; passing `selectors` clicks them in order and asks nothing, which is how a recorded call replays. Otherwise needs " ++ zenai.typesafe.env_var_name ++ ".",
            .summary = "Dismiss a cookie consent banner",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "prefer": { "type": "string", "enum":
            ++ lp.Config.tagJsonArray(tools.consent.Prefer) ++
                \\, "description": "Whether to accept the cookies or refuse all non-essential ones. Defaults to 'accept'." },
                \\    "selectors": { "type": "array", "items": { "type": "string" }, "description": "Optional CSS selectors of the controls to click in order, from an earlier call's result. Clicked without asking the model; one that is not on the page stops the clicking there." }
                \\  }
                \\}
            ),
        },
        .login => .{
            .description = "Sign in on the current page. The browser collects the candidate fields and sign-in controls, asks TypeSafe System One (Jev) only what the markup leaves ambiguous, fills the credentials, submits, and re-reads the page to say whether it worked. A password is only ever typed into an `input[type=password]`, and credentials only go to an https (or loopback) page whose form posts to an https URL. Pass `$LP_*` placeholders rather than literal secrets: they resolve inside the browser and never appear in the result. Returns JSON with the selectors it used, so a recorded call replays them with no model call. Otherwise needs " ++ zenai.typesafe.env_var_name ++ ".",
            .summary = "Sign in, picking the fields with Jev",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "password": { "type": "string", "description": "The password, as a $LP_* placeholder." },
                \\    "username": { "type": "string", "description": "The username, email or other identifier, as a $LP_* placeholder. Omit on a page that asks only for the password." },
                \\    "usernameSelector": { "type": "string", "description": "Optional CSS selector of the identifier field, from an earlier call's result. Given with passwordSelector, the fields are filled with no model call." },
                \\    "passwordSelector": { "type": "string", "description": "Optional CSS selector of the password field, from an earlier call's result. Must name an input[type=password]." },
                \\    "submitSelector": { "type": "string", "description": "Optional CSS selector of the control that submits the form. Without it, Enter is pressed in the filled field." },
                \\    "nextSelector": { "type": "string", "description": "Optional CSS selector of the control that submits the username on a page that asks for the password on a later step. Without it, Enter is pressed in the username field." },
                \\    "decideOnly": { "type": "boolean", "description": "Report which fields would be used and type nothing. For checking the picks on a page without sending credentials." }
                \\  },
                \\  "required": ["password"]
                \\}
            ),
        },
        .tree => .{
            .description = "Semantic outline of the page as indented text: one node per line with its role, accessible name, value and backendNodeId, plus checked state and select options with the selected one marked. The default first read of an unfamiliar page; input and select values are already here, so no `nodeDetails` call is needed to read them. Pass `backendNodeId` to scope to a subtree and `maxDepth` to survey structure before going deeper. Read it again after any page-changing action, since the DOM it describes may have changed; use `nodeDetails` to turn a backendNodeId into a CSS selector for actions.",
            .summary = "Semantic DOM tree of the page",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before fetching the semantic tree. An empty string is treated as omitted." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
                \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID to get the tree for a specific element instead of the document root. 0 is treated as omitted." },
                \\    "maxDepth": { "type": "integer", "description": "Optional maximum depth of the tree to return. Useful for exploring high-level structure first." },
                \\    "maxBytes": { "type": "integer", "description": "Optional cap on output size in bytes. Past it, lines are kept by priority (alerts, dialogs, invalid fields and the focused element, then controls and named nodes, then text; list entries breadth-first), and dropped lines are counted in a '[+N more @id]' marker. id is the backendNodeId of the node holding them, often a list item or list that isn't printed itself: call tree with backendNodeId=id to read them." }
                \\  }
                \\}
            ),
        },
        .nodeDetails => .{
            .description = "Details for a node by backendNodeId: a ready-to-use CSS `selector` that resolves to the node (the first match, as click/fill resolve it), plus tag, role, name, interactivity, disabled, value, input type, placeholder, href, id, class, checked, select options. The canonical way to turn a tree backendNodeId into a CSS selector.",
            .summary = "Inspect a node by backendNodeId",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to inspect." }
                \\  },
                \\  "required": ["backendNodeId"]
                \\}
            ),
        },
        .interactiveElements => .{
            .description = "List every visible interactive element on the page as a JSON array: native controls, ARIA widgets, contenteditable regions, elements with event listeners, and focusable elements. Each entry has `backendNodeId`, `tagName`, `role`, `name`, `type` (why it counts as interactive), `tabIndex`, and when present `listeners`, `disabled`, `id`, `class`, `href`, `inputType`, `value`, `elementName` and `placeholder`. Use it to survey what can be acted on; to locate one element by role or name, `findElement` is cheaper. If a url is provided, it navigates there first.",
            .summary = "List interactive elements on the page",
            .input_schema = url_params_schema,
        },
        .structuredData => .{
            .description = "Page metadata as JSON: `jsonLd` (each JSON-LD block as a string), `openGraph`, `twitterCard`, `meta` and `links` (key/value lists), plus `alternate` (hreflang variants) and `linkHeaders` (relations from the HTTP Link header) when present. Empty sections come back as empty arrays. Use it for publisher-declared facts such as product price, article author or canonical URL before scraping the visible text for them. If a url is provided, it navigates there first.",
            .summary = "Extract JSON-LD / OpenGraph data",
            .input_schema = url_params_schema,
        },
        .detectForms => .{
            .description = "List the forms on the page as JSON: each form's `backendNodeId`, `action`, `method` and `fields`, where each field has `backendNodeId`, `tagName`, `name`, `inputType`, `required`, `disabled`, and when present `value`, `placeholder` and select `options`. Use it before filling a form to see every field it expects. It returns no CSS selectors; get one per field with `nodeDetails` so the fill calls stay replayable. If a url is provided, it navigates there first.",
            .summary = "List forms and their fields",
            .input_schema = url_params_schema,
        },
        .click => .{
            .description = "Click on an interactive element. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Returns the current page URL and title after the click.",
            .summary = "Click an element",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "CSS selector of the element to click. Preferred over backendNodeId." },
                \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to click." }
                \\  }
                \\}
            ),
        },
        .fill => .{
            .description = "Fill text into an input element. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId.",
            .summary = "Type text into an input",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "CSS selector of the input element to fill. Preferred over backendNodeId." },
                \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the input element to fill." },
                \\    "value": { "type": "string", "description": "The text to fill into the input element." }
                \\  },
                \\  "required": ["value"]
                \\}
            ),
        },
        .scroll => .{
            .description = "Scroll the window, or an element's scroll container, to an absolute position; an omitted axis keeps its current offset. Target an element with a CSS selector (preferred for reproducibility) or a backendNodeId; omit both to scroll the window. Page scripts receive a `scroll` event, so content that loads on scroll (infinite feeds, lazy lists) may appear: read the page again afterwards, with `waitForState` if it is still loading. Returns the final scroll position and the current page URL and title.",
            .summary = "Scroll the page or an element",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "Optional: CSS selector of the element to scroll. Preferred over backendNodeId. If the element is not itself a scroll container, its nearest scrollable ancestor is scrolled instead." },
                \\    "backendNodeId": { "type": "integer", "description": "Optional: The backend node ID of the element to scroll. If the element is not itself a scroll container, its nearest scrollable ancestor is scrolled instead. If neither this nor selector is given (or it is 0), scrolls the window." },
                \\    "x": { "type": "integer", "description": "Optional: The horizontal scroll offset." },
                \\    "y": { "type": "integer", "description": "Optional: The vertical scroll offset." }
                \\  }
                \\}
            ),
        },
        .waitForSelector => .{
            .description = "Wait for an element matching a CSS selector to appear in the page. Returns the backend node ID of the matched element.",
            .summary = "Wait for an element to appear",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "The CSS selector to wait for." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 5000, or 15000 when the page has not reached 'load' yet." }
                \\  },
                \\  "required": ["selector"]
                \\}
            ),
        },
        .waitForScript => .{
            .description = "Wait until a JS expression returns truthy. Re-evaluates on each tick of the event loop. Use for synchronization beyond what CSS selectors can express — e.g. `window.dataLoaded === true`, `document.readyState === 'complete'`, `document.querySelectorAll('.row').length >= 5`.",
            .summary = "Wait until a JS expression is truthy",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "script": { "type": "string", "description": "JS expression evaluated each tick until truthy. Must be an expression (not a statement)." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 5000, or 15000 when the page has not reached 'load' yet." }
                \\  },
                \\  "required": ["script"]
                \\}
            ),
        },
        .waitForState => .{
            .description = "Wait for the CURRENT page to reach a load state (no navigation). After a `goto`, the page is returned at the fast `load` snapshot, so content rendered by post-load JS (XHR-loaded lists, feeds, search results) may still be missing. When a read looks incomplete — empty lists, spinners, skeletons — call this with 'networkidle' and re-read. Prefer 'networkidle'; 'done' can be slow on sites with constant background activity (ads, polling).",
            .summary = "Wait for the page to reach a load state",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "state": { "type": "string", "enum": 
            ++ lp.Config.tagJsonArray(lp.Config.WaitUntil) ++
                \\, "description": "Load state to wait for. 'networkidle' = network settled (the usual choice to finish a dynamic page)." },
                \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 5000." }
                \\  },
                \\  "required": ["state"]
                \\}
            ),
        },
        .hover => .{
            .description = "Hover over an element, triggering mouseover and mouseenter events. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Useful for menus, tooltips, and hover states.",
            .summary = "Hover over an element",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "CSS selector of the element to hover over. Preferred over backendNodeId." },
                \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to hover over." }
                \\  }
                \\}
            ),
        },
        .press => .{
            .description = "Press a keyboard key, dispatching keydown and keyup events. Use key names like 'Enter', 'Tab', 'Escape', 'ArrowDown', 'Backspace', or single characters like 'a', '1'. Common shorthand is normalized: 'enter'/'return' → 'Enter', 'esc' → 'Escape', 'up'/'down'/'left'/'right' → 'Arrow*', 'space' → ' '. Pressing 'Enter' on a form input or submit button triggers implicit form submission.",
            .summary = "Press a keyboard key",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "key": { "type": "string", "description": "The key to press (e.g. 'Enter', 'Tab', 'a')." },
                \\    "selector": { "type": "string", "description": "Optional CSS selector of the element to target. Preferred over backendNodeId." },
                \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID of the element to target. Defaults to the document when neither selector nor backendNodeId is provided; 0 is treated as omitted." }
                \\  },
                \\  "required": ["key"]
                \\}
            ),
        },
        .selectOption => .{
            .description = "Select an option in a <select> dropdown element by its value. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Dispatches input and change events.",
            .summary = "Select an option in a dropdown",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "CSS selector of the <select> element. Preferred over backendNodeId." },
                \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the <select> element." },
                \\    "value": { "type": "string", "description": "The value of the option to select." }
                \\  },
                \\  "required": ["value"]
                \\}
            ),
        },
        .setChecked => .{
            .description = "Check or uncheck a checkbox or radio button. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Dispatches input, change, and click events.",
            .summary = "Check or uncheck a box",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "selector": { "type": "string", "description": "CSS selector of the checkbox or radio input element. Preferred over backendNodeId." },
                \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the checkbox or radio input element." },
                \\    "checked": { "type": "boolean", "description": "Whether to check (true) or uncheck (false) the element.", "default": true }
                \\  },
                \\  "required": ["checked"]
                \\}
            ),
        },
        .findElement => .{
            .description = "Find interactive elements by role and/or accessible name. Returns matching elements with their backend node IDs. Useful for locating specific elements without parsing the full semantic tree.",
            .summary = "Find elements by role or name",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "role": { "type": "string", "description": "Optional ARIA role to match (e.g. 'button', 'link', 'textbox', 'checkbox')." },
                \\    "name": { "type": "string", "description": "Optional accessible name to match, case-insensitive: a substring, or a JavaScript regex literal such as /sign (in|up)/ (unanchored; flags i, m, s, u accepted; case-insensitive even without i, prefix (?-i) to make it case-sensitive)." }
                \\  }
                \\}
            ),
        },
        .consoleLogs => .{
            .description = "Get buffered console.log/warn/error messages from the current page. Returns all messages since last call and clears the buffer.",
            .summary = "Read buffered console messages",
            .input_schema = minify(
                \\{ "type": "object", "properties": {} }
            ),
        },
        .getUrl => .{
            .description = "Current page URL. The browser may already have a page loaded (command, replayed script) not visible in this conversation — call this before assuming nothing is loaded when the user references the current page/site. Also useful to verify a navigation or detect a redirect.",
            .summary = "Show the current page URL",
            .input_schema = minify(
                \\{ "type": "object", "properties": {} }
            ),
        },
        .getCookies => .{
            .description = "Cookies stored in the browser. Defaults to cookies whose domain matches the current page's host. Pass `url=<URL>` to filter for another host, or `all=true` to dump every cookie regardless of host. Useful for debugging authentication and session state.",
            .summary = "Show stored cookies",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string", "description": "Restrict output to cookies matching this URL's host. Defaults to the current page. An empty string is treated as omitted." },
                \\    "all": { "type": "boolean", "default": false, "description": "If true, dump every cookie regardless of host. Overrides `url`." }
                \\  }
                \\}
            ),
        },
        .getEnv => .{
            .description = "With `name`: read an LP_* env var (other namespaces report as not set) — for non-secret config only (base URLs, flags). Without `name`: list LP_* names that are set (no values) — safe credential discovery. For secrets, pass `$LP_*` placeholders in tool args; never request a credential by name (the value would land in your context).",
            .summary = "Read or list LP_* env vars",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "name": { "type": "string", "description": "Optional. If provided, must start with LP_; returns the value. If omitted, returns the list of LP_* names that are set." }
                \\  }
                \\}
            ),
        },
        .download => .{
            .description = "Fetch a URL and save the response body to a local file, sending the session's cookies so authenticated sites work. The way to get a binary or large document (PDF, spreadsheet, archive) out of the browser. Nothing is saved unless the status is 200-203 (like Chrome), and a failed download leaves an existing file at `path` untouched. Requires a loaded page — it fails before the first `goto`.",
            .summary = "Fetch a URL with the session's cookies into a file",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string", "description": "Absolute http(s) URL to fetch." },
                \\    "path": { "type": "string", "description": "Relative path (no '..' segments) to save the response body to. Created or overwritten. The response reports the absolute location." }
                \\  },
                \\  "required": ["url", "path"]
                \\}
            ),
        },
        .pageTools => .{
            .description = "List the tools the current page registers for agents through WebMCP (`navigator.modelContext.registerTool`), as JSON with each tool's `name`, `description`, `inputSchema` and hints. A page tool runs the site's own code and can be more reliable than driving its UI; call one with `callPageTool`. Many pages register their tools after `load`: if the list is empty on a page you expect to have tools, call `waitForState` with `networkidle` and list again.",
            .summary = "List the page's WebMCP tools",
            .input_schema = minify(
                \\{ "type": "object", "properties": {} }
            ),
        },
        .callPageTool => .{
            .description = "Call a WebMCP tool the current page registered (see `pageTools`) and return its result: the text of an MCP-style `content` array, or JSON for any other value. A tool that throws or rejects reports its error. The tool runs the site's own code and may change the page or act on the user's account, so treat a tool without `readOnlyHint` like a form submit.",
            .summary = "Call one of the page's WebMCP tools",
            .input_schema = minify(
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "name": { "type": "string", "description": "Tool name, as `pageTools` lists it." },
                \\    "arguments": { "type": "object", "description": "Optional. The tool's input, matching its `inputSchema`. Defaults to {}." }
                \\  },
                \\  "required": ["name"]
                \\}
            ),
        },
    };
}
