const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const log = lp.log;
const tavily = zenai.search.tavily;

const DOMNode = @import("webapi/Node.zig");
const CDPNode = @import("../cdp/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
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

pub const tool_defs = [_]ToolDef{
    .{
        .name = "goto",
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
    .{
        .name = "search",
        .description = "Run a web search and return results as markdown. When TAVILY_API_KEY is set, queries the Tavily Search API and returns a numbered list of {title, url, snippet}. Otherwise (or on Tavily failure) falls back to scraping the DuckDuckGo HTML endpoint — degraded results, may rate-limit on bursty traffic. Prefer this over goto-ing google.com/search directly (Google blocks the browser on User-Agent/TLS).",
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
    .{
        .name = "markdown",
        .description = "Get the page content in markdown format. If a url is provided, it navigates to that url first.",
        .input_schema = url_params_schema,
    },
    .{
        .name = "links",
        .description = "Extract all links in the opened page. If a url is provided, it navigates to that url first.",
        .input_schema = url_params_schema,
    },
    .{
        .name = "eval",
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
    .{
        .name = "tree",
        .description = "Get the page content as a simplified semantic DOM tree for AI reasoning. If a url is provided, it navigates to that url first.",
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
    .{
        .name = "nodeDetails",
        .description = "Get detailed information about a specific node by its backend node ID. Returns tag, role, name, interactivity, disabled state, value, input type, placeholder, href, checked state, and select options.",
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
    .{
        .name = "interactiveElements",
        .description = "Extract interactive elements from the opened page. If a url is provided, it navigates to that url first.",
        .input_schema = url_params_schema,
    },
    .{
        .name = "structuredData",
        .description = "Extract structured data (like JSON-LD, OpenGraph, etc) from the opened page. If a url is provided, it navigates to that url first.",
        .input_schema = url_params_schema,
    },
    .{
        .name = "detectForms",
        .description = "Detect all forms on the page and return their structure including fields, types, and required status. If a url is provided, it navigates to that url first.",
        .input_schema = url_params_schema,
    },
    .{
        .name = "click",
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
    .{
        .name = "fill",
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
    .{
        .name = "scroll",
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
    .{
        .name = "waitForSelector",
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
    .{
        .name = "hover",
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
    .{
        .name = "press",
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
    .{
        .name = "selectOption",
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
    .{
        .name = "setChecked",
        .description = "Check or uncheck a checkbox or radio button. Provide either a CSS selector (preferred for reproducibility) or a backendNodeId. Dispatches input, change, and click events.",
        .input_schema = minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "selector": { "type": "string", "description": "CSS selector of the checkbox or radio input element. Preferred over backendNodeId." },
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the checkbox or radio input element." },
            \\    "checked": { "type": "boolean", "description": "Whether to check (true) or uncheck (false) the element." }
            \\  },
            \\  "required": ["checked"]
            \\}
        ),
    },
    .{
        .name = "findElement",
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
    .{
        .name = "consoleLogs",
        .description = "Get buffered console.log/warn/error messages from the current page. Returns all messages since last call and clears the buffer.",
        .input_schema = minify(
            \\{ "type": "object", "properties": {} }
        ),
    },
    .{
        .name = "getUrl",
        .description = "Get the current page URL. The browser may already have a page loaded from a user slash command or a replayed script that is not visible in this conversation — call this before assuming nothing is loaded whenever the user references the current page/site/website (explicitly or implicitly) or you otherwise lack the URL needed to ground the request. Also useful to verify a navigation or detect a redirect.",
        .input_schema = minify(
            \\{ "type": "object", "properties": {} }
        ),
    },
    .{
        .name = "getCookies",
        .description = "Get all cookies in the browser. Useful for debugging authentication and session state.",
        .input_schema = minify(
            \\{ "type": "object", "properties": {} }
        ),
    },
    .{
        .name = "getEnv",
        .description = "With `name`: read an environment variable from the LP_* namespace (other names are reported as not set). Without `name`: list all LP_* variable names that are set (names only, no values) — safe for discovering what site-scoped credentials are available. Operators commonly name site-scoped values as LP_<SITE>_<FIELD> (e.g. LP_HN_USERNAME, LP_GH_TOKEN). For credentials specifically, do NOT pass `name` — the return value would land in your context. Use $LP_* placeholders in fill values instead: substitution happens inside the Lightpanda subprocess so the secret never reaches the model. getEnv with a name is for non-secret config (base URLs, feature flags, defaults).",
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

/// Comptime-built flat array of tool names, in `tool_defs` order. Use this
/// when callers only need the names (slash-command lookup, MCP `tools/list`).
pub const names: [tool_defs.len][]const u8 = blk: {
    var arr: [tool_defs.len][]const u8 = undefined;
    for (tool_defs, 0..) |td, i| arr[i] = td.name;
    break :blk arr;
};

pub const ToolError = error{
    FrameNotLoaded,
    InvalidParams,
    NodeNotFound,
    NavigationFailed,
    InternalError,
    OutOfMemory,
};

pub const EvalResult = struct {
    text: []const u8,
    is_error: bool = false,
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

const NodeAndPage = struct { node: *DOMNode, page: *lp.Frame };

pub const Action = enum {
    goto,
    search,
    markdown,
    links,
    nodeDetails,
    interactiveElements,
    structuredData,
    detectForms,
    eval,
    tree,
    click,
    fill,
    scroll,
    waitForSelector,
    hover,
    press,
    selectOption,
    setChecked,
    findElement,
    getEnv,
    consoleLogs,
    getUrl,
    getCookies,
};

pub fn call(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    tool_name: []const u8,
    arguments: ?std.json.Value,
) ToolError![]const u8 {
    const action = std.meta.stringToEnum(Action, tool_name) orelse return ToolError.InvalidParams;

    return switch (action) {
        .goto => execGoto(arena, session, registry, arguments),
        .search => execSearch(arena, session, registry, arguments),
        .markdown => execMarkdown(arena, session, registry, arguments),
        .links => execLinks(arena, session, registry, arguments),
        .tree => execTree(arena, session, registry, arguments),
        .nodeDetails => execNodeDetails(arena, session, registry, arguments),
        .interactiveElements => execInteractiveElements(arena, session, registry, arguments),
        .structuredData => execStructuredData(arena, session, registry, arguments),
        .detectForms => execDetectForms(arena, session, registry, arguments),
        .click => execClick(arena, session, registry, arguments),
        .fill => execFill(arena, session, registry, arguments),
        .scroll => execScroll(arena, session, registry, arguments),
        .waitForSelector => execWaitForSelector(arena, session, registry, arguments),
        .hover => execHover(arena, session, registry, arguments),
        .press => execPress(arena, session, registry, arguments),
        .selectOption => execSelectOption(arena, session, registry, arguments),
        .setChecked => execSetChecked(arena, session, registry, arguments),
        .findElement => execFindElement(arena, session, registry, arguments),
        .eval => execEval(arena, session, registry, arguments).text,
        .getEnv => execGetEnv(arena, arguments),
        .consoleLogs => execConsoleLogs(arena, session),
        .getUrl => execGetUrl(session),
        .getCookies => execGetCookies(arena, session),
    };
}

pub fn callEval(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    arguments: ?std.json.Value,
) EvalResult {
    return execEval(arena, session, registry, arguments);
}

/// Run JavaScript against the current page, skipping the JSON parameter
/// round-trip that `callEval` requires. The script need not be 0-terminated;
/// a copy is made internally.
pub fn evalScript(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    script: []const u8,
) EvalResult {
    const z = arena.dupeZ(u8, script) catch return .{ .text = "Error: out of memory", .is_error = true };
    const page = ensurePage(session, registry, null, null, null) catch return .{ .text = "Error: page not loaded", .is_error = true };
    return runEval(arena, page, z);
}

/// JSON-encoded array of `el.textContent.trim()` for every element matching
/// `selector`. Shared between PandaScript's EXTRACT command and the MCP
/// `script_step` extract arm.
pub fn extractText(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    selector: []const u8,
) EvalResult {
    const eval_script = std.fmt.allocPrintSentinel(
        arena,
        "JSON.stringify(Array.from(document.querySelectorAll({s})).map(el => el.textContent.trim()))",
        .{lp.script.stringifyJson(arena, selector)},
        0,
    ) catch return .{ .text = "Error: out of memory", .is_error = true };
    const page = ensurePage(session, registry, null, null, null) catch return .{ .text = "Error: page not loaded", .is_error = true };
    return runEval(arena, page, eval_script);
}

/// Schema-driven extraction. The schema is parsed in Zig so a syntax error
/// surfaces here instead of as a confusing V8 SyntaxError on the spliced
/// walker. Each value in the schema object is one of:
///   "sel"                → first match's textContent.trim() (string|null)
///   ""                   → matched element's own textContent.trim()
///   ["sel"]              → all matches' textContent (string[])
///   {selector, attr}     → first match's attribute (string|null)
///   [{selector, attr}]   → all matches' attributes (string[])
///   [{selector, fields}] → all matches, with `fields` relative to each (object[])
pub fn extractSchema(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *CDPNode.Registry,
    schema_json: []const u8,
) EvalResult {
    const trimmed = std.mem.trim(u8, schema_json, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') {
        return .{ .text = "Error: EXTRACT schema must be a JSON object", .is_error = true };
    }
    const valid = std.json.validate(arena, schema_json) catch
        return .{ .text = "Error: out of memory", .is_error = true };
    if (!valid) {
        return .{ .text = "Error: invalid EXTRACT schema JSON", .is_error = true };
    }

    const script = std.mem.concatWithSentinel(arena, u8, &.{ schema_walker_prefix, schema_json, schema_walker_suffix }, 0) catch
        return .{ .text = "Error: out of memory", .is_error = true };
    const page = ensurePage(session, registry, null, null, null) catch
        return .{ .text = "Error: page not loaded", .is_error = true };
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
    \\  for (const k in schema) out[k] = ext(document, schema[k]);
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

fn execEval(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) EvalResult {
    const Params = struct {
        script: [:0]const u8,
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgs(Params, arena, arguments) catch |err| return .{
        .text = switch (err) {
            error.OutOfMemory => "Error: out of memory",
            error.InvalidParams => "Error: missing or invalid 'script' argument",
        },
        .is_error = true,
    };
    const page = ensurePage(session, registry, args.url, args.timeout, args.waitUntil) catch return .{ .text = "Error: page not loaded", .is_error = true };
    return runEval(arena, page, args.script);
}

fn runEval(arena: std.mem.Allocator, page: *lp.Frame, script: [:0]const u8) EvalResult {
    var ls: lp.js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(script, null) catch |err| {
        const caught = try_catch.caughtOrError(arena, err);
        var aw: std.Io.Writer.Allocating = .init(arena);
        caught.format(&aw.writer) catch {};
        return .{ .text = aw.written(), .is_error = true };
    };

    return .{ .text = js_result.toStringSliceWithAlloc(arena) catch "undefined" };
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
    return if (err == error.InvalidNodeType) ToolError.InvalidParams else ToolError.InternalError;
}

/// If the previous action queued a navigation (form submit, link click,
/// Enter on an input), drive the runner until it completes or times out.
fn awaitQueuedNavigation(session: *lp.Session) ToolError!void {
    const page = session.currentPage() orelse return;
    if (page.queued_navigation.items.len == 0) return;
    var runner = session.runner(.{}) catch return ToolError.InternalError;
    runner.wait(.{ .ms = 10000, .until = .done }) catch return ToolError.NavigationFailed;
}

fn formatActionResult(
    arena: std.mem.Allocator,
    prefix: []const u8,
    selector: ?[]const u8,
    backend_node_id: ?CDPNode.Id,
    suffix: []const u8,
) ToolError![]const u8 {
    const target = if (selector) |sel|
        std.fmt.allocPrint(arena, "selector: {s}", .{sel}) catch return ToolError.InternalError
    else
        std.fmt.allocPrint(arena, "backendNodeId: {d}", .{backend_node_id.?}) catch return ToolError.InternalError;
    return std.fmt.allocPrint(arena, "{s} ({s}){s}", .{ prefix, target, suffix }) catch ToolError.InternalError;
}

fn appendPageContext(arena: std.mem.Allocator, body: []const u8, page: *lp.Frame) ToolError![]const u8 {
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

    try awaitQueuedNavigation(session);

    const page = try requireFrame(session);
    const body = try formatActionResult(arena, "Clicked element", args.selector, args.backendNodeId, "");
    return appendPageContext(arena, body, page);
}

fn execFill(arena: std.mem.Allocator, session: *lp.Session, registry: *CDPNode.Registry, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        value: []const u8 = "",
    };
    const args = try parseArgs(Params, arena, arguments);
    if (args.value.len == 0) return ToolError.InvalidParams;
    const raw_text = args.value;
    const text = try substituteEnvVars(arena, raw_text);
    const resolved = try resolveTarget(session, registry, args.selector, args.backendNodeId);

    lp.actions.fill(resolved.node, text, resolved.page) catch |err| return mapActionError(err);

    // Show the original reference (e.g. $LP_PASSWORD) in the result, not the resolved value
    const suffix = std.fmt.allocPrint(arena, " with \"{s}\"", .{raw_text}) catch return ToolError.InternalError;
    return formatActionResult(arena, "Filled element", args.selector, args.backendNodeId, suffix);
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

    const node = lp.actions.waitForSelector(args.selector, timeout_ms, session) catch |err| {
        if (err == error.InvalidSelector) return ToolError.InvalidParams;
        return ToolError.InternalError;
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

    return formatActionResult(arena, "Hovered element", args.selector, args.backendNodeId, "");
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

    // Pressing Enter on a form input triggers implicit form submission.
    try awaitQueuedNavigation(session);

    const current_page = try requireFrame(session);
    const body = std.fmt.allocPrint(arena, "Pressed key '{s}'", .{args.key}) catch return ToolError.InternalError;
    return appendPageContext(arena, body, current_page);
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
    return formatActionResult(arena, prefix, args.selector, args.backendNodeId, "");
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
    return formatActionResult(arena, "Set element", args.selector, args.backendNodeId, suffix);
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

    const env_names = lpEnvNames() catch return ToolError.InternalError;
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

/// Sorted `LP_*`-prefixed environment-variable names from the current
/// process. Returned slices point into `std.os.environ`, which is stable for
/// the process lifetime; the outer slice is allocated once into a static
/// cache (environ doesn't change at runtime) and shared across callers. Used
/// by the agent REPL completer to offer `$LP_*` Tab completions and by
/// `execGetEnv` for the no-name variant.
pub fn lpEnvNames() error{OutOfMemory}![]const []const u8 {
    lp_env_names_mu.lock();
    defer lp_env_names_mu.unlock();
    if (lp_env_names_cache) |cached| return cached;

    const gpa = std.heap.page_allocator;
    var env_names: std.ArrayList([]const u8) = .empty;
    errdefer env_names.deinit(gpa);
    try env_names.ensureTotalCapacity(gpa, std.os.environ.len);
    for (std.os.environ) |entry| {
        const line = std.mem.span(entry);
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = line[0..eq_idx];
        if (!std.mem.startsWith(u8, name, "LP_")) continue;
        env_names.appendAssumeCapacity(name);
    }
    std.mem.sort([]const u8, env_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const owned = try env_names.toOwnedSlice(gpa);
    lp_env_names_cache = owned;
    return owned;
}

var lp_env_names_mu: std.Thread.Mutex = .{};
var lp_env_names_cache: ?[]const []const u8 = null;

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
    }) catch return ToolError.NavigationFailed;
}

fn resolveNodeAndPage(session: *lp.Session, registry: *CDPNode.Registry, node_id: CDPNode.Id) ToolError!NodeAndPage {
    const page = try requireFrame(session);
    const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
    return .{ .node = node.dom, .page = page };
}

fn resolveBySelector(session: *lp.Session, selector: []const u8) ToolError!NodeAndPage {
    const page = try requireFrame(session);
    const element = Selector.querySelector(page.document.asNode(), selector, page) catch return ToolError.InvalidParams;
    const node = (element orelse return ToolError.NodeNotFound).asNode();
    return .{ .node = node, .page = page };
}

pub const ParseArgsError = error{ OutOfMemory, InvalidParams };

pub fn parseValue(comptime T: type, arena: std.mem.Allocator, value: std.json.Value) ParseArgsError!T {
    return std.json.parseFromValueLeaky(T, arena, value, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidParams,
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

test "substituteEnvVars no vars" {
    const r = try substituteEnvVars(std.testing.allocator, "hello world");
    try std.testing.expectEqualStrings("hello world", r);
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
