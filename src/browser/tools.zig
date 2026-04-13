const std = @import("std");
const lp = @import("lightpanda");

const DOMNode = @import("webapi/Node.zig");
const CDPNode = @import("../cdp/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

pub fn minify(comptime json: []const u8) []const u8 {
    @setEvalBranchQuota(100000);
    return comptime blk: {
        var res: []const u8 = "";
        var in_string = false;
        var escaped = false;
        for (json) |c| {
            if (in_string) {
                res = res ++ [1]u8{c};
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                }
            } else {
                switch (c) {
                    ' ', '\n', '\r', '\t' => continue,
                    '"' => {
                        in_string = true;
                        res = res ++ [1]u8{c};
                    },
                    else => res = res ++ [1]u8{c},
                }
            }
        }
        break :blk res;
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
        .description = "Get the current page URL. Useful to check if a navigation or redirect occurred.",
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
        .description = "Read the value of an environment variable. Useful for retrieving credentials or configuration without hardcoding them.",
        .input_schema = minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "name": { "type": "string", "description": "The environment variable name to read." }
            \\  },
            \\  "required": ["name"]
            \\}
        ),
    },
};

pub const ToolError = error{
    PageNotLoaded,
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

const NodeAndPage = struct { node: *DOMNode, page: *lp.Page };

pub const Action = enum {
    goto,
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
    session: *lp.Session,
    registry: *CDPNode.Registry,
    arena: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
) ToolError![]const u8 {
    const action = std.meta.stringToEnum(Action, tool_name) orelse return ToolError.InvalidParams;

    return switch (action) {
        .eval => execEval(session, registry, arena, arguments).text,
        .getEnv => execGetEnv(arena, arguments),
        .consoleLogs => execConsoleLogs(session, arena),
        .getUrl => execGetUrl(session),
        .getCookies => execGetCookies(session, arena),
        inline else => |tag| @field(@This(), "exec" ++ [1]u8{std.ascii.toUpper(@tagName(tag)[0])} ++ @tagName(tag)[1..])(session, registry, arena, arguments),
    };
}

pub fn callEval(
    session: *lp.Session,
    registry: *CDPNode.Registry,
    arena: std.mem.Allocator,
    arguments: ?std.json.Value,
) EvalResult {
    return execEval(session, registry, arena, arguments);
}

pub fn isKnownTool(tool_name: []const u8) bool {
    return std.meta.stringToEnum(Action, tool_name) != null;
}

fn execGoto(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrErr(GotoParams, arena, arguments) orelse return ToolError.InvalidParams;
    try performGoto(session, registry, args.url, args.timeout, args.waitUntil);
    return "Navigated successfully.";
}

fn execMarkdown(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(page.document.asNode(), .{}, &aw.writer, page) catch
        return ToolError.InternalError;
    return aw.written();
}

fn execLinks(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const links_list = lp.links.collectLinks(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    for (links_list, 0..) |href, i| {
        if (i > 0) aw.writer.writeByte('\n') catch {};
        aw.writer.writeAll(href) catch {};
    }
    return aw.written();
}

fn execTree(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
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
        .page = page,
        .arena = arena,
        .prune = true,
        .max_depth = args.maxDepth orelse std.math.maxInt(u32) - 1,
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    st.textStringify(&aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execNodeDetails(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { backendNodeId: CDPNode.Id };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;

    const page = session.currentPage() orelse return ToolError.PageNotLoaded;

    const node = registry.lookup_by_id.get(args.backendNodeId) orelse
        return ToolError.NodeNotFound;
    const details = lp.SemanticTree.getNodeDetails(arena, node.dom, registry, page) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(&details, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execInteractiveElements(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const elements = lp.interactive.collectInteractiveElements(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    lp.interactive.registerNodes(elements, registry) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(elements, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execStructuredData(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const data = lp.structured_data.collectStructuredData(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(data, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execDetectForms(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const forms_data = lp.forms.collectForms(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;
    lp.forms.registerNodes(forms_data, registry) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(forms_data, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execEval(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) EvalResult {
    const Params = struct {
        script: [:0]const u8,
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = (parseArgsOrErr(Params, arena, arguments) catch return .{ .text = "Error: out of memory", .is_error = true }) orelse
        return .{ .text = "Error: missing 'script' argument", .is_error = true };
    const page = ensurePage(session, registry, args.url, args.timeout, args.waitUntil) catch return .{ .text = "Error: page not loaded", .is_error = true };

    var ls: lp.js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(args.script, null) catch |err| {
        const caught = try_catch.caughtOrError(arena, err);
        var aw: std.Io.Writer.Allocating = .init(arena);
        caught.format(&aw.writer) catch {};
        return .{ .text = aw.written(), .is_error = true };
    };

    return .{ .text = js_result.toStringSliceWithAlloc(arena) catch "undefined" };
}

fn execClick(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
    };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = if (args.selector) |sel|
        try resolveBySelector(session, sel)
    else if (args.backendNodeId) |nid|
        try resolveNodeAndPage(session, registry, nid)
    else
        return ToolError.InvalidParams;

    lp.actions.click(resolved.node, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    // If the click triggered a navigation (e.g. form submission, link click),
    // wait for it to complete.
    if (session.queued_navigation.items.len != 0) {
        var runner = session.runner(.{}) catch return ToolError.InternalError;
        runner.wait(.{ .ms = 10000, .until = .done }) catch return ToolError.NavigationFailed;
    }

    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const page_title = page.getTitle() catch null;
    if (args.selector) |sel| {
        return std.fmt.allocPrint(arena, "Clicked element (selector: {s}). Page url: {s}, title: {s}", .{
            sel, page.url, page_title orelse "(none)",
        }) catch return ToolError.InternalError;
    }
    return std.fmt.allocPrint(arena, "Clicked element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId.?,
        page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execFill(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        value: []const u8 = "",
    };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    if (args.value.len == 0) return ToolError.InvalidParams;
    const raw_text = args.value;
    const text = substituteEnvVars(arena, raw_text);
    const resolved = if (args.selector) |sel|
        try resolveBySelector(session, sel)
    else if (args.backendNodeId) |nid|
        try resolveNodeAndPage(session, registry, nid)
    else
        return ToolError.InvalidParams;

    lp.actions.fill(resolved.node, text, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    // Show the original reference (e.g. $LP_PASSWORD) in the result, not the resolved value
    const display_text = if (text.ptr != raw_text.ptr) raw_text else text;
    const page_title = resolved.page.getTitle() catch null;
    if (args.selector) |sel| {
        return std.fmt.allocPrint(arena, "Filled element (selector: {s}) with \"{s}\". Page url: {s}, title: {s}", .{
            sel, display_text, resolved.page.url, page_title orelse "(none)",
        }) catch return ToolError.InternalError;
    }
    return std.fmt.allocPrint(arena, "Filled element (backendNodeId: {d}) with \"{s}\". Page url: {s}, title: {s}", .{
        args.backendNodeId.?,
        display_text,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execScroll(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
        target_node = node.dom;
    }

    lp.actions.scroll(target_node, args.x, args.y, page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const page_title = page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Scrolled to x: {d}, y: {d}. Page url: {s}, title: {s}", .{
        args.x orelse 0,
        args.y orelse 0,
        page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execWaitForSelector(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        selector: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;

    _ = session.currentPage() orelse return ToolError.PageNotLoaded;

    const timeout_ms = args.timeout orelse 5000;

    const node = lp.actions.waitForSelector(args.selector, timeout_ms, session) catch |err| {
        if (err == error.InvalidSelector) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const registered = registry.register(node) catch return ToolError.InternalError;
    return std.fmt.allocPrint(arena, "Element found. backendNodeId: {d}", .{registered.id}) catch return ToolError.InternalError;
}

fn execHover(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
    };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = if (args.selector) |sel|
        try resolveBySelector(session, sel)
    else if (args.backendNodeId) |nid|
        try resolveNodeAndPage(session, registry, nid)
    else
        return ToolError.InvalidParams;

    lp.actions.hover(resolved.node, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const page_title = resolved.page.getTitle() catch null;
    if (args.selector) |sel| {
        return std.fmt.allocPrint(arena, "Hovered element (selector: {s}). Page url: {s}, title: {s}", .{
            sel, resolved.page.url, page_title orelse "(none)",
        }) catch return ToolError.InternalError;
    }
    return std.fmt.allocPrint(arena, "Hovered element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId.?,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execPress(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        key: []const u8,
        backendNodeId: ?CDPNode.Id = null,
    };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;

    const page = session.currentPage() orelse return ToolError.PageNotLoaded;

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
        target_node = node.dom;
    }

    lp.actions.press(target_node, args.key, page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    // Pressing Enter on a form input triggers implicit form submission.
    if (session.queued_navigation.items.len != 0) {
        var runner = session.runner(.{}) catch return ToolError.InternalError;
        runner.wait(.{ .ms = 10000, .until = .done }) catch return ToolError.NavigationFailed;
    }

    const current_page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const page_title = current_page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Pressed key '{s}'. Page url: {s}, title: {s}", .{
        args.key,
        current_page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execSelectOption(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        value: []const u8,
    };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = if (args.selector) |sel|
        try resolveBySelector(session, sel)
    else if (args.backendNodeId) |nid|
        try resolveNodeAndPage(session, registry, nid)
    else
        return ToolError.InvalidParams;

    lp.actions.selectOption(resolved.node, args.value, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const page_title = resolved.page.getTitle() catch null;
    if (args.selector) |sel| {
        return std.fmt.allocPrint(arena, "Selected option '{s}' (selector: {s}). Page url: {s}, title: {s}", .{
            args.value, sel, resolved.page.url, page_title orelse "(none)",
        }) catch return ToolError.InternalError;
    }
    return std.fmt.allocPrint(arena, "Selected option '{s}' (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.value,
        args.backendNodeId.?,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execSetChecked(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        checked: bool,
    };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = if (args.selector) |sel|
        try resolveBySelector(session, sel)
    else if (args.backendNodeId) |nid|
        try resolveNodeAndPage(session, registry, nid)
    else
        return ToolError.InvalidParams;

    lp.actions.setChecked(resolved.node, args.checked, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const state_str = if (args.checked) "checked" else "unchecked";
    const page_title = resolved.page.getTitle() catch null;
    if (args.selector) |sel| {
        return std.fmt.allocPrint(arena, "Set element (selector: {s}) to {s}. Page url: {s}, title: {s}", .{
            sel, state_str, resolved.page.url, page_title orelse "(none)",
        }) catch return ToolError.InternalError;
    }
    return std.fmt.allocPrint(arena, "Set element (backendNodeId: {d}) to {s}. Page url: {s}, title: {s}", .{
        args.backendNodeId.?,
        state_str,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execFindElement(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        role: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);

    if (args.role == null and args.name == null) return ToolError.InvalidParams;

    const page = session.currentPage() orelse return ToolError.PageNotLoaded;

    const elements = lp.interactive.collectInteractiveElements(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;

    var matches: std.ArrayListUnmanaged(lp.interactive.InteractiveElement) = .empty;
    for (elements) |el| {
        if (args.role) |role| {
            const el_role = el.role orelse continue;
            if (!std.ascii.eqlIgnoreCase(el_role, role)) continue;
        }
        if (args.name) |name| {
            const el_name = el.name orelse continue;
            if (std.ascii.indexOfIgnoreCase(el_name, name) == null) continue;
        }
        matches.append(arena, el) catch return ToolError.InternalError;
    }

    const matched = matches.toOwnedSlice(arena) catch return ToolError.InternalError;
    lp.interactive.registerNodes(matched, registry) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(matched, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execGetEnv(arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { name: []const u8 };
    const args = try parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const name_z = arena.dupeZ(u8, args.name) catch return ToolError.InternalError;
    const value = std.posix.getenv(name_z) orelse
        return std.fmt.allocPrint(arena, "Environment variable '{s}' is not set", .{args.name}) catch ToolError.InternalError;
    return value;
}

fn execConsoleLogs(
    session: *lp.Session,
    arena: std.mem.Allocator,
) ToolError![]const u8 {
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const messages = page.drainConsoleMessages();
    if (messages.len == 0) return "No console messages.";

    var aw: std.Io.Writer.Allocating = .init(arena);
    const writer = &aw.writer;
    for (messages) |msg| {
        writer.print("[{s}] {s}\n", .{ @tagName(msg.level), msg.text }) catch return ToolError.InternalError;
    }
    return aw.written();
}

fn execGetUrl(session: *lp.Session) ToolError![]const u8 {
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    return page.url;
}

fn execGetCookies(session: *lp.Session, arena: std.mem.Allocator) ToolError![]const u8 {
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

fn ensurePage(session: *lp.Session, registry: *CDPNode.Registry, url: ?[:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) ToolError!*lp.Page {
    if (url) |u| {
        try performGoto(session, registry, u, timeout, waitUntil);
    }
    return session.currentPage() orelse ToolError.PageNotLoaded;
}

fn performGoto(session: *lp.Session, registry: *CDPNode.Registry, url: [:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) ToolError!void {
    if (session.page != null) {
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
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
    return .{ .node = node.dom, .page = page };
}

fn resolveBySelector(session: *lp.Session, selector: []const u8) ToolError!NodeAndPage {
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const element = Selector.querySelector(page.document.asNode(), selector, page) catch return ToolError.InvalidParams;
    const node = (element orelse return ToolError.NodeNotFound).asNode();
    return .{ .node = node, .page = page };
}

fn parseArgsOrDefault(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) error{OutOfMemory}!T {
    const args_raw = arguments orelse return .{};
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{},
    };
}

fn parseArgsOrErr(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) error{OutOfMemory}!?T {
    const args_raw = arguments orelse return null;
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

pub fn substituteEnvVars(arena: std.mem.Allocator, input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '$') == null) return input;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$') {
            const var_start = i + 1;
            var var_end = var_start;
            while (var_end < input.len and (std.ascii.isAlphanumeric(input[var_end]) or input[var_end] == '_')) {
                var_end += 1;
            }
            if (var_end > var_start) {
                const var_name_z = arena.dupeZ(u8, input[var_start..var_end]) catch return input;
                if (std.posix.getenv(var_name_z)) |env_val| {
                    result.appendSlice(arena, env_val) catch return input;
                } else {
                    result.appendSlice(arena, input[i..var_end]) catch return input;
                }
                i = var_end;
            } else {
                result.append(arena, '$') catch return input;
                i += 1;
            }
        } else {
            result.append(arena, input[i]) catch return input;
            i += 1;
        }
    }
    return result.toOwnedSlice(arena) catch input;
}

test "substituteEnvVars no vars" {
    const r = substituteEnvVars(std.testing.allocator, "hello world");
    try std.testing.expectEqualStrings("hello world", r);
}

test "substituteEnvVars with HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const r = substituteEnvVars(arena.allocator(), "dir=$HOME/test");
    try std.testing.expect(std.mem.indexOf(u8, r, "$HOME") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "/test") != null);
}

test "substituteEnvVars missing var kept literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const r = substituteEnvVars(arena.allocator(), "$UNLIKELY_VAR_12345");
    try std.testing.expectEqualStrings("$UNLIKELY_VAR_12345", r);
}

test "substituteEnvVars bare dollar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const r = substituteEnvVars(arena.allocator(), "price is $ 5");
    try std.testing.expectEqualStrings("price is $ 5", r);
}
