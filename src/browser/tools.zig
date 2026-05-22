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

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const log = lp.log;
const tavily = zenai.search.tavily;

const DOMNode = @import("webapi/Node.zig");
const CDPNode = @import("../cdp/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");

/// Hand-written so per-tool semantics (record/heal/locator/data) and
/// LLM-facing metadata (`definition`) live as exhaustive switches on the
/// tag — adding a new tool is a compile error until each predicate AND
/// `definition` make an explicit choice. `tool_defs` (below) materializes
/// `definition` over every tag for callers that iterate.
pub const Tool = enum {
    goto,
    search,
    markdown,
    links,
    eval,
    extract,
    tree,
    nodeDetails,
    interactiveElements,
    structuredData,
    detectForms,
    click,
    fill,
    scroll,
    waitForSelector,
    hover,
    press,
    selectOption,
    setChecked,
    findElement,
    consoleLogs,
    getUrl,
    getCookies,
    getEnv,

    /// State-mutating: surfaces in `.lp` recordings. Read-only tools
    /// (queries, env probes) stay out so a replay doesn't bloat the script
    /// with noise.
    pub fn isRecorded(self: Tool) bool {
        return switch (self) {
            .goto, .eval, .extract, .click, .fill, .scroll, .waitForSelector, .hover, .press, .selectOption, .setChecked => true,
            .search, .markdown, .links, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// Safe target for the self-heal LLM to emit when a recorded step
    /// fails. Only deterministic per-element actions; anything that depends
    /// on prior page state or LLM judgment is excluded.
    pub fn canHeal(self: Tool) bool {
        return switch (self) {
            .click, .fill, .scroll, .waitForSelector, .hover, .press, .selectOption, .setChecked, .extract => true,
            .goto, .search, .markdown, .links, .eval, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// Tool requires a target element (selector or backendNodeId) at
    /// runtime even though the JSON schema marks both as optional. Used by
    /// the recorder to skip lines that can't be replayed.
    pub fn needsLocator(self: Tool) bool {
        return switch (self) {
            .click, .fill, .hover, .selectOption, .setChecked => true,
            .goto, .search, .markdown, .links, .eval, .extract, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .scroll, .waitForSelector, .press, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// Result is data the caller probably wants on stdout (extracted JSON,
    /// markdown, eval return value) rather than a status line on stderr.
    pub fn producesData(self: Tool) bool {
        return switch (self) {
            .search, .markdown, .links, .eval, .extract, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => true,
            .goto, .click, .fill, .scroll, .waitForSelector, .hover, .press, .selectOption, .setChecked => false,
        };
    }

    /// Tool execution is retryable on element interaction failure (e.g. if
    /// the element is detached, not visible yet, or covered).
    pub fn isRetryable(self: Tool) bool {
        return switch (self) {
            .fill, .setChecked, .selectOption => true,
            .goto, .search, .markdown, .links, .eval, .extract, .tree, .nodeDetails, .interactiveElements, .structuredData, .detectForms, .click, .scroll, .waitForSelector, .hover, .press, .findElement, .consoleLogs, .getUrl, .getCookies, .getEnv => false,
        };
    }

    /// Per-tool LLM-facing metadata. Tool identity (name + predicates) lives
    /// on the enclosing `Tool` enum; this struct just carries the strings.
    pub const Definition = struct {
        description: []const u8,
        input_schema: []const u8,
    };

    /// Source of truth for tool ↔ metadata. The exhaustive switch makes
    /// adding a new `Tool` tag a compile error until its description and
    /// JSON schema exist. `tool_defs` (below) materializes the array form
    /// for callers that iterate (MCP `tools/list`, schema build).
    pub fn definition(self: Tool) Definition {
        return switch (self) {
            .goto => .{
                .description = "Navigate to a specified URL and load the page in memory so it can be reused later for info extraction.",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "url": { "type": "string", "description": "The URL to navigate to, must be a valid URL." },
                    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
                    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
                    \\  },
                    \\  "required": ["url"]
                    \\}
                ),
            },
            .search => .{
                .description = "Run a web search and return results as markdown. When TAVILY_API_KEY is set, queries the Tavily Search API and returns a numbered list of {title, url, snippet}. Otherwise (or on Tavily failure) falls back to scraping the DuckDuckGo HTML endpoint — degraded results, may rate-limit on bursty traffic. Prefer this over goto-ing google.com/search directly (Google blocks the browser on User-Agent/TLS). Browser state after this call is unspecified — to interact with a result, use `goto` with its URL; do not assume the browser DOM matches the results page.",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "query": { "type": "string", "description": "The search query." },
                    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
                    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
                    \\  },
                    \\  "required": ["query"]
                    \\}
                ),
            },
            .markdown => .{
                .description = "Get the page content in markdown format. If a url is provided, it navigates to that url first.",
                .input_schema = url_params_schema,
            },
            .links => .{
                .description = "Extract all links in the opened page. If a url is provided, it navigates to that url first.",
                .input_schema = url_params_schema,
            },
            .eval => .{
                .description = "Evaluate JavaScript in the current page context. If a url is provided, it navigates to that url first.",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "script": { "type": "string" },
                    \\    "url": { "type": "string", "description": "Optional URL to navigate to before evaluating." },
                    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
                    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
                    \\  },
                    \\  "required": ["script"]
                    \\}
                ),
            },
            .extract => .{
                .description =
                \\Extract structured data from the current page using a small JSON schema. Prefer this over `markdown` or `eval` whenever the user asked for a specific value or list (a score, price, count, profile field, headlines, …) — the result is returned as JSON AND the call is recorded as an `/extract` PandaScript line, so a later replay (no LLM) prints the answer to stdout. Use `markdown` / `tree` / `interactiveElements` only to discover the right selector, then commit to one `extract` call.
                \\
                \\Schema is a JSON object literal (pass it as a string in `schema`). Each value picks what to lift out:
                \\  "<sel>"                                → first match's textContent.trim() (string|null)
                \\  ""                                     → element's own textContent.trim() (only meaningful inside `fields`)
                \\  ["<sel>"]                              → every match's text (string[])
                \\  {"selector":"<sel>","attr":"<name>"}   → first match's attribute (string|null)
                \\  [{"selector":"<sel>","attr":"<name>"}] → every match's attribute (string[])
                \\  [{"selector":"<sel>","fields":{…}}]    → array of objects, fields resolved relative to each match
                \\
                \\Examples (schema → result):
                \\  {"karma": "#karma"} → {"karma":"42"}
                \\  {"items": [".story .title"]} → {"items":["Title 1","Title 2"]}
                \\  {"links": [{"selector":"a.title","attr":"href"}]} → {"links":["/a","/b"]}
                \\  {"stories": [{"selector":".athing","fields":{"title":".titleline","rank":".rank"}}]} → {"stories":[{"title":"Foo","rank":"1"}]}
                ,
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "schema": { "type": "string", "description": "JSON schema object (as a string) describing what to extract. Must be a JSON object literal." }
                    \\  },
                    \\  "required": ["schema"]
                    \\}
                ),
            },
            .tree => .{
                .description = "Simplified semantic DOM tree (role, name, value, backendNodeId per node). Output omits raw HTML attributes; call `nodeDetails` on a backendNodeId to read id/class for selector synthesis. Navigates first if `url` is provided.",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "url": { "type": "string", "description": "Optional URL to navigate to before fetching the semantic tree." },
                    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
                    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "done"], "description": "Optional wait strategy. Defaults to 'done'." },
                    \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID to get the tree for a specific element instead of the document root." },
                    \\    "maxDepth": { "type": "integer", "description": "Optional maximum depth of the tree to return. Useful for exploring high-level structure first." }
                    \\  }
                    \\}
                ),
            },
            .nodeDetails => .{
                .description = "Details for a node by backendNodeId: tag, role, name, interactivity, disabled, value, input type, placeholder, href, **id**, **class**, checked, select options. Canonical way to turn a tree backendNodeId into a CSS selector.",
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
                .description = "Extract interactive elements from the opened page. If a url is provided, it navigates to that url first.",
                .input_schema = url_params_schema,
            },
            .structuredData => .{
                .description = "Extract structured data (like JSON-LD, OpenGraph, etc) from the opened page. If a url is provided, it navigates to that url first.",
                .input_schema = url_params_schema,
            },
            .detectForms => .{
                .description = "Detect all forms on the page and return their structure including fields, types, and required status. If a url is provided, it navigates to that url first.",
                .input_schema = url_params_schema,
            },
            .click => .{
                .description = "Click on an interactive element. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Returns the current page URL and title after the click.",
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
                .description = "Scroll the page or a specific element. Returns the scroll position and current page URL and title.",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "backendNodeId": { "type": "integer", "description": "Optional: The backend node ID of the element to scroll. If omitted, scrolls the window." },
                    \\    "x": { "type": "integer", "description": "Optional: The horizontal scroll offset." },
                    \\    "y": { "type": "integer", "description": "Optional: The vertical scroll offset." }
                    \\  }
                    \\}
                ),
            },
            .waitForSelector => .{
                .description = "Wait for an element matching a CSS selector to appear in the page. Returns the backend node ID of the matched element.",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "selector": { "type": "string", "description": "The CSS selector to wait for." },
                    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 5000." }
                    \\  },
                    \\  "required": ["selector"]
                    \\}
                ),
            },
            .hover => .{
                .description = "Hover over an element, triggering mouseover and mouseenter events. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Useful for menus, tooltips, and hover states.",
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
                .description = "Press a keyboard key, dispatching keydown and keyup events. Use key names like 'Enter', 'Tab', 'Escape', 'ArrowDown', 'Backspace', or single characters like 'a', '1'.",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "key": { "type": "string", "description": "The key to press (e.g. 'Enter', 'Tab', 'a')." },
                    \\    "backendNodeId": { "type": "integer", "description": "Optional backend node ID of the element to target. Defaults to the document." }
                    \\  },
                    \\  "required": ["key"]
                    \\}
                ),
            },
            .selectOption => .{
                .description = "Select an option in a <select> dropdown element by its value. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Dispatches input and change events.",
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
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "role": { "type": "string", "description": "Optional ARIA role to match (e.g. 'button', 'link', 'textbox', 'checkbox')." },
                    \\    "name": { "type": "string", "description": "Optional accessible name substring to match (case-insensitive)." }
                    \\  }
                    \\}
                ),
            },
            .consoleLogs => .{
                .description = "Get buffered console.log/warn/error messages from the current page. Returns all messages since last call and clears the buffer.",
                .input_schema = minify(
                    \\{ "type": "object", "properties": {} }
                ),
            },
            .getUrl => .{
                .description = "Current page URL. The browser may already have a page loaded (slash command, replayed script) not visible in this conversation — call this before assuming nothing is loaded when the user references the current page/site. Also useful to verify a navigation or detect a redirect.",
                .input_schema = minify(
                    \\{ "type": "object", "properties": {} }
                ),
            },
            .getCookies => .{
                .description = "Get all cookies in the browser. Useful for debugging authentication and session state.",
                .input_schema = minify(
                    \\{ "type": "object", "properties": {} }
                ),
            },
            .getEnv => .{
                .description = "With `name`: read an LP_* env var (other namespaces report as not set) — for non-secret config only (base URLs, flags). Without `name`: list LP_* names that are set (no values) — safe credential discovery. For secrets, pass `$LP_*` placeholders in tool args; never request a credential by name (the value would land in your context).",
                .input_schema = minify(
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "name": { "type": "string", "description": "Optional. If provided, must start with LP_; returns the value. If omitted, returns the list of LP_* names that are set." }
                    \\  }
                    \\}
                ),
            },
        };
    }
};

pub fn minify(comptime json: []const u8) []const u8 {
    @setEvalBranchQuota(10000);
    return comptime blk: {
        var buf: [json.len]u8 = undefined;
        var len: usize = 0;
        var in_string = false;
        var escaped = false;
        for (json) |c| {
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                }
            } else switch (c) {
                ' ', '\n', '\r', '\t' => continue,
                '"' => in_string = true,
                else => {},
            }
            buf[len] = c;
            len += 1;
        }
        const final = buf[0..len].*;
        break :blk &final;
    };
}

const url_params_schema = minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "url": { "type": "string", "description": "Optional URL to navigate to before processing." },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
    \\  }
    \\}
);

/// Materialized form of `Tool.definition` keyed by `@intFromEnum(Tool)`.
/// Built at comptime by iterating every `Tool` tag — order and count
/// can't drift because both come from the enum itself.
pub const tool_defs: [@typeInfo(Tool).@"enum".fields.len]Tool.Definition = blk: {
    var arr: [@typeInfo(Tool).@"enum".fields.len]Tool.Definition = undefined;
    for (std.enums.values(Tool), 0..) |t, i| arr[i] = t.definition();
    break :blk arr;
};

/// Comptime-built flat array of tool names, in `Tool` declaration order.
/// Use this when callers only need the names (slash-command lookup, MCP
/// `tools/list`).
pub const names: [@typeInfo(Tool).@"enum".fields.len][]const u8 = blk: {
    const fields = @typeInfo(Tool).@"enum".fields;
    var arr: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| arr[i] = f.name;
    break :blk arr;
};

pub const ToolError = error{
    FrameNotLoaded,
    InvalidParams,
    NodeNotFound,
    NavigationFailed,
    Cancelled,
    InternalError,
    OutOfMemory,
};

/// Outcome of running a tool against the page. Operational failures (OOM,
/// missing page, invalid params) come out as Zig errors on the enclosing
/// `!ToolResult`; `is_error = true` is the in-band signal for a JS-level
/// failure (V8 caught a throw inside `eval`/`extract`) — the LLM consumes
/// `text` either way to self-correct. Non-eval tools always set `is_error =
/// false` on success.
pub const ToolResult = struct {
    text: []const u8,
    is_error: bool = false,

    /// The text payload only when the tool succeeded; `null` on failure.
    /// Convenient for callers (e.g. `Verifier`) that bail on any error.
    pub fn okText(self: ToolResult) ?[]const u8 {
        return if (self.is_error) null else self.text;
    }
};

pub const GotoParams = struct {
    url: [:0]const u8,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

pub const UrlParams = struct {
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

const ActionTarget = union(enum) {
    selector: []const u8,
    backend_node_id: CDPNode.Id,

    pub fn format(self: ActionTarget, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .selector => |sel| try writer.print("selector: {s}", .{sel}),
            .backend_node_id => |id| try writer.print("backendNodeId: {d}", .{id}),
        }
    }
};

const NodeAndPage = struct { node: *DOMNode, page: *lp.Frame, target: ActionTarget };

pub fn call(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    tool_name: []const u8,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const tool = std.meta.stringToEnum(Tool, tool_name) orelse return ToolError.InvalidParams;
    if (diagnoseArgs(arena, arguments)) |msg|
        return .{ .text = msg, .is_error = true };
    const substituted = try substituteStringArgs(arena, tool, arguments);

    return dispatch(arena, session, registry, tool, substituted) catch |err| {
        if (err == error.NavigationFailed) {
            if (formatNavigationError(arena, session)) |text|
                return .{ .text = text, .is_error = true };
        }
        return err;
    };
}

fn dispatch(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    tool: Tool,
    substituted: ?std.json.Value,
) ToolError!ToolResult {
    return switch (tool) {
        .goto => .{ .text = try execGoto(arena, session, registry, substituted) },
        .search => .{ .text = try execSearch(arena, session, registry, substituted) },
        .markdown => .{ .text = try execMarkdown(arena, session, registry, substituted) },
        .links => .{ .text = try execLinks(arena, session, registry, substituted) },
        .tree => .{ .text = try execTree(arena, session, registry, substituted) },
        .nodeDetails => .{ .text = try execNodeDetails(arena, session, registry, substituted) },
        .interactiveElements => .{ .text = try execInteractiveElements(arena, session, registry, substituted) },
        .structuredData => .{ .text = try execStructuredData(arena, session, registry, substituted) },
        .detectForms => .{ .text = try execDetectForms(arena, session, registry, substituted) },
        .click => .{ .text = try execClick(arena, session, registry, substituted) },
        .fill => .{ .text = try execFill(arena, session, registry, substituted) },
        .scroll => .{ .text = try execScroll(arena, session, registry, substituted) },
        .waitForSelector => .{ .text = try execWaitForSelector(arena, session, registry, substituted) },
        .hover => .{ .text = try execHover(arena, session, registry, substituted) },
        .press => .{ .text = try execPress(arena, session, registry, substituted) },
        .selectOption => .{ .text = try execSelectOption(arena, session, registry, substituted) },
        .setChecked => .{ .text = try execSetChecked(arena, session, registry, substituted) },
        .findElement => .{ .text = try execFindElement(arena, session, registry, substituted) },
        .eval => execEval(arena, session, registry, substituted),
        .extract => execExtract(arena, session, registry, substituted),
        .getEnv => .{ .text = try execGetEnv(arena, substituted) },
        .consoleLogs => .{ .text = try execConsoleLogs(arena, session) },
        .getUrl => .{ .text = try execGetUrl(session) },
        .getCookies => .{ .text = try execGetCookies(arena, session) },
    };
}

fn formatNavigationError(arena: std.mem.Allocator, session: *lp.Session) ?[]const u8 {
    const frame = session.currentFrame() orelse return null;
    const err = frame._last_navigate_error orelse return null;
    return std.fmt.allocPrint(arena, "navigation failed: {s}", .{@errorName(err)}) catch null;
}

/// Run JavaScript against the current page. The script need not be
/// 0-terminated; a copy is made internally.
pub fn evalScript(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    script: []const u8,
) ToolError!ToolResult {
    const z = try arena.dupeZ(u8, script);
    const page = try ensurePage(session, registry, null, null, null);
    return runEval(arena, page, z);
}

/// Schema-driven extraction. The schema is parsed in Zig so a syntax error
/// surfaces here instead of as a confusing V8 SyntaxError on the spliced
/// walker.
pub fn extract(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    schema_json: []const u8,
) ToolError!ToolResult {
    const trimmed = std.mem.trim(u8, schema_json, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return error.InvalidParams;
    const valid = try std.json.validate(arena, schema_json);
    if (!valid) return error.InvalidParams;

    const script = try std.mem.concatWithSentinel(arena, u8, &.{ schema_walker_prefix, schema_json, schema_walker_suffix }, 0);
    const page = try ensurePage(session, registry, null, null, null);
    return runEval(arena, page, script);
}

// The schema literal is spliced between prefix and suffix verbatim — a format
// string here would collide with the `{`/`}` throughout the walker body.
const schema_walker_prefix =
    \\JSON.stringify((function(schema){
    \\  function valueOf(m, inner){
    \\    if (inner.fields) {
    \\      const r = {};
    \\      for (const k in inner.fields) r[k] = ext(m, inner.fields[k]);
    \\      return r;
    \\    }
    \\    if (inner.attr) return m.getAttribute(inner.attr);
    \\    return m.textContent.trim();
    \\  }
    \\  function ext(el, v){
    \\    if (typeof v === 'string') {
    \\      if (v === '') return el.textContent.trim();
    \\      const m = el.querySelector(v);
    \\      return m ? m.textContent.trim() : null;
    \\    }
    \\    if (Array.isArray(v)) {
    \\      const inner = v[0];
    \\      if (typeof inner === 'string') {
    \\        return Array.from(el.querySelectorAll(inner)).map(function(m){ return m.textContent.trim(); });
    \\      }
    \\      return Array.from(el.querySelectorAll(inner.selector)).map(function(m){ return valueOf(m, inner); });
    \\    }
    \\    const t = v.selector ? el.querySelector(v.selector) : el;
    \\    if (!t) return null;
    \\    return valueOf(t, v);
    \\  }
    \\  const out = {};
    \\  let any = false;
    \\  for (const k in schema) {
    \\    out[k] = ext(document, schema[k]);
    \\    const v = out[k];
    \\    if (v !== null && !(Array.isArray(v) && v.length === 0)) any = true;
    \\  }
    \\  if (!any) throw new Error("extract: no schema selector matched any element — inspect the page with tree/markdown and retry with corrected selectors");
    \\  return out;
    \\})(
;
const schema_walker_suffix = "))";

fn execGoto(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgs(GotoParams, arena, arguments);
    try performGoto(session, registry, args.url, args.timeout, args.waitUntil);
    return "Navigated successfully.";
}

pub const SearchParams = struct {
    query: []const u8,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

fn execSearch(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgs(SearchParams, arena, arguments);
    if (args.query.len == 0) return ToolError.InvalidParams;

    // Tavily path: only when TAVILY_API_KEY is set in the process env. On any
    // failure (network, non-2xx, parse) fall through to the DuckDuckGo scrape
    // so a single Tavily outage doesn't kill a whole benchmark run.
    if (std.posix.getenv("TAVILY_API_KEY")) |api_key| {
        if (tavilySearch(arena, api_key, args.query)) |markdown_| {
            return markdown_;
        } else |err| {
            log.warn(.browser, "tavily fallback", .{ .err = err });
        }
    }

    const encoded = lp.URL.percentEncodeSegment(arena, args.query, .component) catch return ToolError.OutOfMemory;
    const ddg_url = std.fmt.allocPrintSentinel(
        arena,
        "https://html.duckduckgo.com/html/?q={s}",
        .{encoded},
        0,
    ) catch return ToolError.OutOfMemory;
    try performGoto(session, registry, ddg_url, args.timeout, args.waitUntil);
    const ddg_frame = try requireFrame(session);
    return renderFrameMarkdown(arena, ddg_frame);
}

// Thin wrapper over `zenai.search.tavily.Client` that handles client
// lifetime and renders the structured response as markdown for the agent.
// `arena` owns the returned slice. `api_key` is the value of TAVILY_API_KEY.
fn tavilySearch(
    arena: std.mem.Allocator,
    api_key: []const u8,
    query: []const u8,
) ![]const u8 {
    var client: tavily.Client = .init(arena, api_key, .{});
    defer client.deinit();

    var response = client.search(query, .{ .max_results = 10 }) catch |err| {
        if (client.last_error_status) |status| {
            log.warn(.browser, "tavily non-2xx", .{
                .status = status,
                .body = client.last_error_body orelse "",
            });
        }
        return err;
    };
    defer response.deinit();

    return formatTavilyMarkdown(arena, response.value);
}

fn formatTavilyMarkdown(arena: std.mem.Allocator, resp: tavily.types.SearchResponse) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    if (resp.answer) |a| {
        if (a.len > 0) {
            try w.print("**Answer:** {s}\n\n", .{a});
        }
    }
    for (resp.results, 0..) |r, i| {
        try w.print("{d}. **{s}** — {s}\n   {s}\n\n", .{ i + 1, r.title, r.url, r.content });
    }
    if (resp.results.len == 0 and (resp.answer == null or resp.answer.?.len == 0)) {
        try w.writeAll("No results.");
    }
    return aw.written();
}

fn renderFrameMarkdown(arena: std.mem.Allocator, frame: *lp.Frame) ToolError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(frame.document.asNode(), .{}, &aw.writer, frame) catch
        return ToolError.InternalError;
    return aw.written();
}

fn execMarkdown(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);
    return renderFrameMarkdown(arena, page);
}

fn execLinks(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const links_list = lp.links.collectLinks(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;

    return std.mem.join(arena, "\n", links_list) catch return ToolError.InternalError;
}

fn execTree(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const TreeParams = struct {
        url: ?[:0]const u8 = null,
        backendNodeId: ?u32 = null,
        maxDepth: ?u32 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = try parseArgsOrDefault(TreeParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    var root_node = page.document.asNode();
    if (args.backendNodeId) |node_id| {
        if (registry.lookup_by_id.get(node_id)) |n| {
            root_node = n.dom;
        }
    }

    const st = lp.SemanticTree{
        .dom_node = root_node,
        .registry = registry,
        .frame = page,
        .arena = arena,
        .prune = true,
        .max_depth = args.maxDepth orelse std.math.maxInt(u32) - 1,
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    st.textStringify(&aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execNodeDetails(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { backendNodeId: CDPNode.Id };
    const args = try parseArgs(Params, arena, arguments);

    const page = try requireFrame(session);

    const node = registry.lookup_by_id.get(args.backendNodeId) orelse
        return ToolError.NodeNotFound;
    const details = lp.SemanticTree.getNodeDetails(arena, node.dom, registry, page) catch
        return ToolError.InternalError;
    return renderJson(arena, &details);
}

fn execInteractiveElements(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const elements = lp.interactive.collectInteractiveElements(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    lp.interactive.registerNodes(elements, registry) catch
        return ToolError.InternalError;
    return renderJson(arena, elements);
}

fn execStructuredData(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const data = lp.structured_data.collectStructuredData(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    return renderJson(arena, data);
}

fn execDetectForms(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const forms_data = lp.forms.collectForms(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;
    lp.forms.registerNodes(forms_data, registry) catch
        return ToolError.InternalError;
    return renderJson(arena, forms_data);
}

fn execEval(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        script: [:0]const u8,
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = try parseArgs(Params, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);
    return runEval(arena, page, args.script);
}

fn execExtract(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct { schema: []const u8 };
    const args = try parseArgs(Params, arena, arguments);
    return extract(arena, session, registry, args.schema);
}

fn runEval(arena: std.mem.Allocator, page: *lp.Frame, script: [:0]const u8) ToolError!ToolResult {
    var ls: lp.js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(script, null) catch |err|
        return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true };

    const text = js_result.toStringSliceWithAlloc(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true },
    };
    return .{ .text = text };
}

fn formatJsError(arena: std.mem.Allocator, try_catch: *lp.js.TryCatch, err: anyerror) error{OutOfMemory}![]const u8 {
    const caught = try_catch.caughtOrError(arena, err);
    var aw: std.Io.Writer.Allocating = .init(arena);
    caught.format(&aw.writer) catch |fmt_err| switch (fmt_err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.written();
}

/// Resolve a target element from either a CSS selector or a backendNodeId.
fn resolveTarget(
    session: *lp.Session,
    registry: *CDPNode.Registry,
    selector: ?[]const u8,
    backend_node_id: ?CDPNode.Id,
) ToolError!NodeAndPage {
    if (selector) |sel| return resolveBySelector(session, sel);
    if (backend_node_id) |nid| return resolveNodeAndPage(session, registry, nid);
    return ToolError.InvalidParams;
}

/// Look up an optional DOM node by backendNodeId. Returns null when no id was
/// supplied, errors when the id doesn't resolve.
fn resolveOptionalNode(registry: *CDPNode.Registry, backend_node_id: ?CDPNode.Id) ToolError!?*DOMNode {
    const id = backend_node_id orelse return null;
    const node = registry.lookup_by_id.get(id) orelse return ToolError.NodeNotFound;
    return node.dom;
}

fn mapActionError(err: anytype) ToolError {
    if (err == error.InvalidNodeType) return ToolError.InvalidParams;
    log.debug(.browser, "action error", .{ .err = @errorName(err) });
    return ToolError.InternalError;
}

/// If the previous action queued a navigation (form submit, link click,
/// Enter on an input), drive the runner until it completes or times out.
fn awaitQueuedNavigation(session: *lp.Session) ToolError!void {
    const page = session.currentPage() orelse return;
    if (page.queued_navigation.items.len == 0) return;
    var runner = session.runner(.{}) catch return ToolError.InternalError;
    runner.wait(.{ .ms = 10000, .until = .done }) catch |err|
        return if (err == error.Cancelled) ToolError.Cancelled else ToolError.NavigationFailed;
}

fn formatActionResult(
    arena: std.mem.Allocator,
    prefix: []const u8,
    target: ActionTarget,
    suffix: []const u8,
) ToolError![]const u8 {
    return std.fmt.allocPrint(arena, "{s} ({f}){s}", .{ prefix, target, suffix }) catch ToolError.InternalError;
}

/// Finish a state-changing action: drain any queued navigation triggered by
/// the action, then tag `body` with the resulting page URL and title so the
/// caller (LLM, MCP client) can see whether the action triggered navigation.
fn finalizeAction(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, body: []const u8) ToolError![]const u8 {
    const before = session.currentFrame();
    try awaitQueuedNavigation(session);
    const page = try requireFrame(session);
    // A queued navigation that swaps the root frame tears down the previous
    // Page (`Session.replaceRootImmediate` / `commitPendingPage`), so every
    // DOMNode pointer in the registry now dangles. Drop the registry so the
    // next action can't dereference freed memory.
    if (before != null and before.? != page) registry.reset();
    const page_title = page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "{s}. Page url: {s}, title: {s}", .{
        body, page.url, page_title orelse "(none)",
    }) catch ToolError.InternalError;
}

fn execClick(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    lp.actions.click(resolved.node, resolved.page) catch |err| return mapActionError(err);

    const body = try formatActionResult(arena, "Clicked element", resolved.target, "");
    return finalizeAction(arena, session, registry, body);
}

fn execFill(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        value: []const u8 = "",
    };
    const args = try parseArgs(Params, arena, arguments);
    const raw_text = args.value;
    const text = try substituteEnvVars(arena, raw_text);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    lp.actions.fill(resolved.node, text, resolved.page) catch |err| return mapActionError(err);

    // Show the original reference (e.g. $LP_PASSWORD) in the result, not the resolved value
    const suffix = std.fmt.allocPrint(arena, " with \"{s}\"", .{raw_text}) catch return ToolError.InternalError;
    const body = try formatActionResult(arena, "Filled element", resolved.target, suffix);
    return finalizeAction(arena, session, registry, body);
}

fn execScroll(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    const page = try requireFrame(session);
    const target_node = try resolveOptionalNode(registry, args.backendNodeId);

    lp.actions.scroll(target_node, args.x, args.y, page) catch |err| return mapActionError(err);

    return std.fmt.allocPrint(arena, "Scrolled to x: {d}, y: {d}", .{
        args.x orelse 0,
        args.y orelse 0,
    }) catch return ToolError.InternalError;
}

fn execWaitForSelector(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        selector: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = try parseArgs(Params, arena, arguments);

    _ = try requireFrame(session);

    const timeout_ms = args.timeout orelse 5000;

    const node = lp.actions.waitForSelector(args.selector, timeout_ms, session) catch |err| switch (err) {
        error.InvalidSelector => return ToolError.InvalidParams,
        error.Cancelled => return ToolError.Cancelled,
        // Timeout w/o a match: same outcome as `/hover selector=…` on a missing
        // node — surface `NodeNotFound` so the LLM sees a consistent signal.
        error.Timeout => return ToolError.NodeNotFound,
        else => {
            log.debug(.browser, "waitForSelector error", .{ .err = @errorName(err) });
            return ToolError.InternalError;
        },
    };

    const registered = registry.register(node) catch return ToolError.InternalError;
    return std.fmt.allocPrint(arena, "Element found. backendNodeId: {d}", .{registered.id}) catch return ToolError.InternalError;
}

fn execHover(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    lp.actions.hover(resolved.node, resolved.page) catch |err| return mapActionError(err);

    const body = try formatActionResult(arena, "Hovered element", resolved.target, "");
    return finalizeAction(arena, session, registry, body);
}

fn execPress(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        key: []const u8,
        backendNodeId: ?CDPNode.Id = null,
    };
    const args = try parseArgs(Params, arena, arguments);

    const page = try requireFrame(session);
    const target_node = try resolveOptionalNode(registry, args.backendNodeId);

    lp.actions.press(target_node, args.key, page) catch |err| return mapActionError(err);

    // Pressing Enter on a form input triggers implicit form submission;
    // `finalizeAction` drains the queued navigation before tagging the body.
    const body = std.fmt.allocPrint(arena, "Pressed key '{s}'", .{args.key}) catch return ToolError.InternalError;
    return finalizeAction(arena, session, registry, body);
}

fn execSelectOption(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        value: []const u8,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    lp.actions.selectOption(resolved.node, args.value, resolved.page) catch |err| return mapActionError(err);

    const prefix = std.fmt.allocPrint(arena, "Selected option '{s}'", .{args.value}) catch return ToolError.InternalError;
    const body = try formatActionResult(arena, prefix, resolved.target, "");
    return finalizeAction(arena, session, registry, body);
}

fn execSetChecked(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        checked: bool,
    };
    const args = try parseArgs(Params, arena, arguments);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    lp.actions.setChecked(resolved.node, args.checked, resolved.page) catch |err| return mapActionError(err);

    const state_str: []const u8 = if (args.checked) "checked" else "unchecked";
    const suffix = std.fmt.allocPrint(arena, " to {s}", .{state_str}) catch return ToolError.InternalError;
    const body = try formatActionResult(arena, "Set element", resolved.target, suffix);
    return finalizeAction(arena, session, registry, body);
}

fn execFindElement(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        role: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);

    if (args.role == null and args.name == null) return ToolError.InvalidParams;

    const page = try requireFrame(session);

    const matched = lp.interactive.findInteractiveElements(page.document.asNode(), arena, page, .{
        .role = args.role,
        .name = args.name,
    }) catch return ToolError.InternalError;

    lp.interactive.registerNodes(matched, registry) catch
        return ToolError.InternalError;
    return renderJson(arena, matched);
}

fn execGetEnv(arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { name: ?[]const u8 = null };
    const args = try parseArgsOrDefault(Params, arena, arguments);

    if (args.name) |name| {
        if (lookupLpEnv(name)) |value| return value;
        return std.fmt.allocPrint(arena, "Environment variable '{s}' is not set", .{name}) catch ToolError.InternalError;
    }

    const env_names = lpEnvNames(arena) catch return ToolError.InternalError;
    return formatLpEnvNames(arena, env_names);
}

fn formatLpEnvNames(arena: std.mem.Allocator, env_names: []const []const u8) ToolError![]const u8 {
    if (env_names.len == 0) return "No LP_* environment variables are set.";
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("LP_* environment variables ({d}):\n", .{env_names.len}) catch return ToolError.InternalError;
    for (env_names) |n| {
        aw.writer.print("  {s}\n", .{n}) catch return ToolError.InternalError;
    }
    return aw.written();
}

/// Walks `std.c.environ` (live) and dupes names into `arena` — `setenv`
/// can free both the environ array and its entry strings, so a captured
/// `std.os.environ` slice or name pointers into entries would dangle.
pub fn lpEnvNames(arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    var env_names: std.ArrayList([]const u8) = .empty;
    var ptr = std.c.environ;
    while (ptr[0]) |entry| : (ptr += 1) {
        const line = std.mem.span(entry);
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = line[0..eq_idx];
        if (!std.mem.startsWith(u8, name, "LP_")) continue;
        try env_names.append(arena, try arena.dupe(u8, name));
    }
    std.mem.sort([]const u8, env_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return env_names.toOwnedSlice(arena);
}

/// Resolve an LP_-prefixed environment variable, or `null` for any other name.
/// Only the LP_ namespace is readable from the model; everything else
/// (provider API keys, system env, third-party secrets) is hidden so the LLM
/// can't probe for it. Same pattern as Kakoune's `kak_*`.
fn lookupLpEnv(name: []const u8) ?[:0]const u8 {
    if (!std.mem.startsWith(u8, name, "LP_")) return null;
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) {
        log.warn(.browser, "getEnv name too long", .{ .name_len = name.len, .limit = name_buf.len - 1 });
        return null;
    }
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    return std.posix.getenv(name_buf[0..name.len :0]);
}

fn execConsoleLogs(arena: std.mem.Allocator, session: *lp.Session) ToolError![]const u8 {
    const text = session.drainConsoleMessages();
    if (text.len == 0) return "No console messages.";
    return arena.dupe(u8, text) catch ToolError.InternalError;
}

fn execGetUrl(session: *lp.Session) ToolError![]const u8 {
    const page = try requireFrame(session);
    return page.url;
}

/// URL of the active frame, or a stable placeholder when no page is loaded.
/// Use from contexts that just want a string for display/logging; callers
/// that need to react to "no page" should check `currentFrame()` directly.
pub fn currentUrlOrPlaceholder(session: *lp.Session) []const u8 {
    const frame = session.currentFrame() orelse return "(no page loaded)";
    return frame.url;
}

fn execGetCookies(arena: std.mem.Allocator, session: *lp.Session) ToolError![]const u8 {
    const cookies = session.cookie_jar.cookies.items;
    if (cookies.len == 0) return "No cookies.";

    var aw: std.Io.Writer.Allocating = .init(arena);
    const writer = &aw.writer;
    for (cookies) |*cookie| {
        writer.print("{s}={s}", .{ cookie.name, cookie.value }) catch return ToolError.InternalError;
        writer.print("; domain={s}; path={s}", .{ cookie.domain, cookie.path }) catch return ToolError.InternalError;
        if (cookie.secure) writer.writeAll("; Secure") catch return ToolError.InternalError;
        if (cookie.http_only) writer.writeAll("; HttpOnly") catch return ToolError.InternalError;
        writer.writeAll("\n") catch return ToolError.InternalError;
    }
    return aw.written();
}

fn requireFrame(session: *lp.Session) ToolError!*lp.Frame {
    return session.currentFrame() orelse ToolError.FrameNotLoaded;
}

fn renderJson(arena: std.mem.Allocator, value: anytype) ToolError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn ensurePage(session: *lp.Session, registry: *CDPNode.Registry, url: ?[:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) ToolError!*lp.Frame {
    if (url) |u| {
        if (session.currentFrame()) |frame| {
            if (std.mem.eql(u8, frame.url, u)) return frame;
        }
        try performGoto(session, registry, u, timeout, waitUntil);
    }
    return session.currentFrame() orelse ToolError.FrameNotLoaded;
}

fn performGoto(session: *lp.Session, registry: *CDPNode.Registry, url: [:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) ToolError!void {
    if (session.hasPage()) {
        registry.reset();
        session.removePage();
    }
    const page = session.createPage() catch return ToolError.NavigationFailed;
    _ = page.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch return ToolError.NavigationFailed;

    var runner = session.runner(.{}) catch return ToolError.NavigationFailed;
    runner.wait(.{
        .ms = timeout orelse 10000,
        .until = waitUntil orelse .done,
    }) catch |err| return if (err == error.Cancelled) ToolError.Cancelled else ToolError.NavigationFailed;

    const frame = session.currentFrame() orelse return ToolError.NavigationFailed;
    if (frame._last_navigate_error != null) return ToolError.NavigationFailed;
}

fn resolveNodeAndPage(session: *lp.Session, registry: *CDPNode.Registry, node_id: CDPNode.Id) ToolError!NodeAndPage {
    const page = try requireFrame(session);
    const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
    return .{ .node = node.dom, .page = page, .target = .{ .backend_node_id = node_id } };
}

fn resolveBySelector(session: *lp.Session, selector: []const u8) ToolError!NodeAndPage {
    const page = try requireFrame(session);
    const element = Selector.querySelector(page.document.asNode(), selector, page) catch return ToolError.InvalidParams;
    const node = (element orelse return ToolError.NodeNotFound).asNode();
    return .{ .node = node, .page = page, .target = .{ .selector = selector } };
}

pub const ParseArgsError = error{ OutOfMemory, InvalidParams };

/// Surface field/value context for known typed args — `std.json`'s parse
/// errors only carry the tag (`InvalidEnumTag`, …), not which field failed.
fn diagnoseArgs(arena: std.mem.Allocator, arguments: ?std.json.Value) ?[]const u8 {
    const args = arguments orelse return null;
    if (args != .object) return null;

    if (args.object.get("waitUntil")) |v| switch (v) {
        .string => |s| if (std.meta.stringToEnum(lp.Config.WaitUntil, s) == null)
            return formatEnumError(arena, "waitUntil", s, lp.Config.WaitUntil),
        else => return std.fmt.allocPrint(arena, "waitUntil must be a string", .{}) catch null,
    };

    return null;
}

fn formatEnumError(arena: std.mem.Allocator, field: []const u8, got: []const u8, comptime E: type) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("invalid {s} '{s}'. Expected one of: ", .{ field, got }) catch return null;
    inline for (std.meta.fields(E), 0..) |f, i| {
        if (i > 0) aw.writer.writeAll(", ") catch return null;
        aw.writer.writeAll(f.name) catch return null;
    }
    return aw.written();
}

pub fn parseValue(comptime T: type, arena: std.mem.Allocator, value: std.json.Value) ParseArgsError!T {
    return std.json.parseFromValueLeaky(T, arena, value, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            log.debug(.browser, "parseValue rejected", .{ .err = @errorName(err), .type = @typeName(T) });
            return error.InvalidParams;
        },
    };
}

/// For tools where every field is optional. Missing args → default `T`;
/// wrong-typed args still error (don't silently default).
pub fn parseArgsOrDefault(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) ParseArgsError!T {
    return parseValue(T, arena, arguments orelse return .{});
}

/// Required-args parse: missing or malformed both surface as `InvalidParams`.
pub fn parseArgs(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) ParseArgsError!T {
    return parseValue(T, arena, arguments orelse return error.InvalidParams);
}

/// Resolve `$LP_*` placeholders in every string arg before the tool runs.
/// `fill.value` is the one exception: `execFill` resolves it internally and
/// echoes the original placeholder so the credential never surfaces in the
/// result text. Co-located with `execFill` so both halves of the carve-out
/// live in one file.
fn substituteStringArgs(arena: std.mem.Allocator, tool: Tool, args: ?std.json.Value) error{OutOfMemory}!?std.json.Value {
    const v = args orelse return null;
    if (v != .object) return v;

    const is_fill = tool == .fill;

    const needsSub = struct {
        fn f(is_fill_: bool, key: []const u8, val: std.json.Value) bool {
            if (is_fill_ and std.mem.eql(u8, key, "value")) return false;
            return val == .string and std.mem.indexOf(u8, val.string, "$LP_") != null;
        }
    }.f;

    var it = v.object.iterator();
    while (it.next()) |entry| {
        if (needsSub(is_fill, entry.key_ptr.*, entry.value_ptr.*)) break;
    } else return v;

    var new_obj: std.json.ObjectMap = .init(arena);
    try new_obj.ensureTotalCapacity(v.object.count());
    it = v.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const new_val: std.json.Value = if (needsSub(is_fill, key, val))
            .{ .string = try substituteEnvVars(arena, val.string) }
        else
            val;
        try new_obj.put(key, new_val);
    }
    return .{ .object = new_obj };
}

pub fn substituteEnvVars(arena: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]const u8 {
    // No `$LP_` prefix → no substitution possible, skip the rebuild entirely.
    // Pages routinely contain `$5.99`-style content where `$` is incidental.
    // Lowercase `$lp_…` falls through here too — `std.posix.getenv` is
    // case-sensitive on Linux, so it would never resolve anyway.
    const first_lp = std.mem.indexOf(u8, input, "$LP_") orelse return input;

    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(arena, input.len);
    var i: usize = first_lp;
    var last_copy: usize = 0;
    while (std.mem.indexOfScalarPos(u8, input, i, '$')) |dollar| {
        const var_start = dollar + 1;
        var var_end = var_start;
        while (var_end < input.len and (std.ascii.isAlphanumeric(input[var_end]) or input[var_end] == '_')) {
            var_end += 1;
        }
        if (var_end == var_start) {
            i = dollar + 1;
            continue;
        }
        const name = input[var_start..var_end];
        if (lookupLpEnv(name)) |val| {
            try result.appendSlice(arena, input[last_copy..dollar]);
            try result.appendSlice(arena, val);
            last_copy = var_end;
        }
        i = var_end;
    }
    if (last_copy == 0) return input;
    try result.appendSlice(arena, input[last_copy..]);
    return result.toOwnedSlice(arena);
}

/// Inverse of `substituteEnvVars`, used by the recorder so a credential the
/// agent retyped as a literal doesn't leak into the recording. Values < 4
/// chars are skipped to avoid false-positive substring matches.
pub fn reverseSubstituteEnvVars(arena: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]const u8 {
    if (input.len < 4) return input;
    const env_names = try lpEnvNames(arena);

    // Iterate by value length descending. With two LP_* values where one is a
    // substring of the other (both ≥4 chars so neither is filtered), name-order
    // iteration would let the shorter value clobber part of the longer one
    // before its full match is found, leaking a suffix into the recording.
    const Pair = struct { name: []const u8, value: []const u8 };
    var pairs: std.ArrayList(Pair) = .empty;
    try pairs.ensureTotalCapacity(arena, env_names.len);
    for (env_names) |name| {
        const value = lookupLpEnv(name) orelse continue;
        if (value.len < 4) continue;
        pairs.appendAssumeCapacity(.{ .name = name, .value = value });
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.value.len > b.value.len;
        }
    }.lt);

    var current: []const u8 = input;
    var changed = false;
    for (pairs.items) |p| {
        if (std.mem.indexOf(u8, current, p.value) == null) continue;
        const placeholder = try std.fmt.allocPrint(arena, "${s}", .{p.name});
        current = try std.mem.replaceOwned(u8, arena, current, p.value, placeholder);
        changed = true;
    }
    return if (changed) current else input;
}

test "substituteEnvVars resolves LP_* vars" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const var_name = "LP_SUBST_TEST";
    const var_value = "secret";
    _ = setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = unsetenv(@constCast(var_name));

    const r = try substituteEnvVars(arena.allocator(), "user=$LP_SUBST_TEST/end");
    try std.testing.expectEqualStrings("user=secret/end", r);
}

test "substituteEnvVars keeps non-LP_ refs literal even when set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // `execGetEnv` hides non-LP_ vars from the model; `substituteEnvVars`
    // must hide them too, otherwise a prompt-injected `fill('$X')` would
    // resolve the value into the page DOM.
    const var_name = "LIGHTPANDA_SUBST_TEST_OUTSIDE";
    const var_value = "should-not-leak";
    _ = setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = unsetenv(@constCast(var_name));

    const r = try substituteEnvVars(arena.allocator(), "$LIGHTPANDA_SUBST_TEST_OUTSIDE");
    try std.testing.expectEqualStrings("$LIGHTPANDA_SUBST_TEST_OUTSIDE", r);
}

test "substituteEnvVars missing LP_ var kept literal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const r = try substituteEnvVars(arena.allocator(), "$LP_UNLIKELY_VAR_12345");
    try std.testing.expectEqualStrings("$LP_UNLIKELY_VAR_12345", r);
}

test "substituteEnvVars bare dollar" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const r = try substituteEnvVars(arena.allocator(), "price is $ 5");
    try std.testing.expectEqualStrings("price is $ 5", r);
}

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

test "execGetEnv reads LP_* values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const var_name = "LP_GETENV_TEST_OK";
    const var_value = "hello-world";
    _ = setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = unsetenv(@constCast(var_name));

    var obj: std.json.ObjectMap = .init(aa);
    try obj.put("name", .{ .string = var_name });
    const arguments: std.json.Value = .{ .object = obj };

    const r = try execGetEnv(aa, arguments);
    try std.testing.expectEqualStrings(var_value, r);
}

test "execGetEnv hides non-LP_ values even when set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const var_name = "LIGHTPANDA_GETENV_TEST_OUTSIDE";
    const var_value = "should-not-leak";
    _ = setenv(@constCast(var_name), @constCast(var_value), 1);
    defer _ = unsetenv(@constCast(var_name));

    var obj: std.json.ObjectMap = .init(aa);
    try obj.put("name", .{ .string = var_name });
    const arguments: std.json.Value = .{ .object = obj };

    const r = try execGetEnv(aa, arguments);
    try std.testing.expect(std.mem.indexOf(u8, r, var_value) == null);
    try std.testing.expectEqualStrings(
        "Environment variable '" ++ var_name ++ "' is not set",
        r,
    );
}

test "formatLpEnvNames renders names without values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const env_names = [_][]const u8{ "LP_BAR", "LP_FOO" };
    const r = try formatLpEnvNames(aa, &env_names);

    try std.testing.expect(std.mem.indexOf(u8, r, "LP_FOO") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "LP_BAR") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "secret") == null);
}

test "formatLpEnvNames reports empty when no names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const r = try formatLpEnvNames(aa, &.{});
    try std.testing.expectEqualStrings("No LP_* environment variables are set.", r);
}

test "formatTavilyMarkdown renders answer and results" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const resp: tavily.types.SearchResponse = .{
        .query = "capital of france",
        .answer = "Paris",
        .results = &.{
            .{ .title = "Paris - Wikipedia", .url = "https://en.wikipedia.org/wiki/Paris", .content = "Paris is the capital of France." },
            .{ .title = "France", .url = "https://example.org/fr", .content = "Country in Western Europe." },
        },
    };

    const md = try formatTavilyMarkdown(aa, resp);
    try std.testing.expect(std.mem.indexOf(u8, md, "**Answer:** Paris") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "1. **Paris - Wikipedia**") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "https://en.wikipedia.org/wiki/Paris") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Paris is the capital of France.") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "2. **France**") != null);
}

test "formatTavilyMarkdown handles empty results" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const resp: tavily.types.SearchResponse = .{};
    const md = try formatTavilyMarkdown(aa, resp);
    try std.testing.expectEqualStrings("No results.", md);
}
