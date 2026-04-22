const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;
const js = lp.js;

const DOMNode = @import("../browser/webapi/Node.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const CDPNode = @import("../cdp/Node.zig");

const goto_schema = protocol.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "url": { "type": "string", "description": "The URL to navigate to, must be a valid URL." },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
    \\  },
    \\  "required": ["url"]
    \\}
);

const url_params_schema = protocol.minify(
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "url": { "type": "string", "description": "Optional URL to navigate to before processing." },
    \\    "timeout": { "type": "integer", "description": "Optional timeout in milliseconds. Defaults to 10000." },
    \\    "waitUntil": { "type": "string", "enum": ["load", "domcontentloaded", "networkidle", "done"], "description": "Optional wait strategy. Defaults to 'done'." }
    \\  }
    \\}
);

const evaluate_schema = protocol.minify(
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
);

pub const tool_list = [_]protocol.Tool{
    .{
        .name = "goto",
        .description = "Navigate to a specified URL and load the page in memory so it can be reused later for info extraction.",
        .inputSchema = goto_schema,
    },
    .{
        .name = "navigate",
        .description = "Alias for goto. Navigate to a specified URL and load the page in memory.",
        .inputSchema = goto_schema,
    },
    .{
        .name = "markdown",
        .description = "Get the page content in markdown format. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .name = "links",
        .description = "Extract all links in the opened frame. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .name = "evaluate",
        .description = "Evaluate JavaScript in the current page context. If a url is provided, it navigates to that url first.",
        .inputSchema = evaluate_schema,
    },
    .{
        .name = "eval",
        .description = "Alias for evaluate. Evaluate JavaScript in the current page context.",
        .inputSchema = evaluate_schema,
    },
    .{
        .name = "semantic_tree",
        .description = "Get the page content as a simplified semantic DOM tree for AI reasoning. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
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
        .inputSchema = protocol.minify(
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
        .description = "Extract interactive elements from the opened frame. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .name = "structuredData",
        .description = "Extract structured data (like JSON-LD, OpenGraph, etc) from the opened frame. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .name = "detectForms",
        .description = "Detect all forms on the page and return their structure including fields, types, and required status. If a url is provided, it navigates to that url first.",
        .inputSchema = url_params_schema,
    },
    .{
        .name = "click",
        .description = "Click on an interactive element. Returns the current page URL and title after the click.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to click." }
            \\  },
            \\  "required": ["backendNodeId"]
            \\}
        ),
    },
    .{
        .name = "fill",
        .description = "Fill text into an input element. Returns the filled value and current page URL and title.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the input element to fill." },
            \\    "text": { "type": "string", "description": "The text to fill into the input element." }
            \\  },
            \\  "required": ["backendNodeId", "text"]
            \\}
        ),
    },
    .{
        .name = "scroll",
        .description = "Scroll the page or a specific element. Returns the scroll position and current page URL and title.",
        .inputSchema = protocol.minify(
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
        .description = "Wait for an element matching a CSS selector to appear in the frame. Returns the backend node ID of the matched element.",
        .inputSchema = protocol.minify(
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
        .description = "Hover over an element, triggering mouseover and mouseenter events. Useful for menus, tooltips, and hover states.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the element to hover over." }
            \\  },
            \\  "required": ["backendNodeId"]
            \\}
        ),
    },
    .{
        .name = "press",
        .description = "Press a keyboard key, dispatching keydown and keyup events. Use key names like 'Enter', 'Tab', 'Escape', 'ArrowDown', 'Backspace', or single characters like 'a', '1'.",
        .inputSchema = protocol.minify(
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
        .description = "Select an option in a <select> dropdown element by its value. Dispatches input and change events.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the <select> element." },
            \\    "value": { "type": "string", "description": "The value of the option to select." }
            \\  },
            \\  "required": ["backendNodeId", "value"]
            \\}
        ),
    },
    .{
        .name = "setChecked",
        .description = "Check or uncheck a checkbox or radio button. Dispatches input, change, and click events.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "backendNodeId": { "type": "integer", "description": "The backend node ID of the checkbox or radio input element." },
            \\    "checked": { "type": "boolean", "description": "Whether to check (true) or uncheck (false) the element." }
            \\  },
            \\  "required": ["backendNodeId", "checked"]
            \\}
        ),
    },
    .{
        .name = "findElement",
        .description = "Find interactive elements by role and/or accessible name. Returns matching elements with their backend node IDs. Useful for locating specific elements without parsing the full semantic tree.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "role": { "type": "string", "description": "Optional ARIA role to match (e.g. 'button', 'link', 'textbox', 'checkbox')." },
            \\    "name": { "type": "string", "description": "Optional accessible name substring to match (case-insensitive)." }
            \\  }
            \\}
        ),
    },
};

pub fn handleList(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    _ = arena;
    const id = req.id orelse return;
    try server.sendResult(id, .{ .tools = &tool_list });
}

const GotoParams = struct {
    url: [:0]const u8,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

const UrlParams = struct {
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

const EvaluateParams = struct {
    script: [:0]const u8,
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

const ToolStreamingText = struct {
    frame: *lp.Frame,
    action: enum { markdown, links, semantic_tree },
    registry: ?*CDPNode.Registry = null,
    arena: ?std.mem.Allocator = null,
    backendNodeId: ?u32 = null,
    maxDepth: ?u32 = null,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        var escaped: protocol.JsonEscapingWriter = .init(jw.writer);
        const w = &escaped.writer;

        switch (self.action) {
            .markdown => lp.markdown.dump(self.frame.document.asNode(), .{}, w, self.frame) catch |err| {
                log.err(.mcp, "markdown dump failed", .{ .err = err });
                return error.WriteFailed;
            },
            .links => {
                const links = lp.links.collectLinks(self.frame.call_arena, self.frame.document.asNode(), self.frame) catch |err| {
                    log.err(.mcp, "query links failed", .{ .err = err });
                    return error.WriteFailed;
                };
                var first = true;
                for (links) |href| {
                    if (!first) try w.writeByte('\n');
                    try w.writeAll(href);
                    first = false;
                }
            },
            .semantic_tree => {
                var root_node = self.frame.document.asNode();
                if (self.backendNodeId) |node_id| {
                    if (self.registry) |registry| {
                        if (registry.lookup_by_id.get(node_id)) |n| {
                            root_node = n.dom;
                        } else {
                            log.warn(.mcp, "semantic_tree id missing", .{ .id = node_id });
                        }
                    }
                }

                const st = lp.SemanticTree{
                    .dom_node = root_node,
                    .registry = self.registry.?,
                    .frame = self.frame,
                    .arena = self.arena.?,
                    .prune = true,
                    .max_depth = self.maxDepth orelse std.math.maxInt(u32) - 1,
                };

                st.textStringify(w) catch |err| {
                    log.err(.mcp, "semantic tree dump failed", .{ .err = err });
                    return error.WriteFailed;
                };
            },
        }

        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }
};

const ToolAction = enum {
    goto,
    navigate,
    markdown,
    links,
    nodeDetails,
    interactiveElements,
    structuredData,
    detectForms,
    evaluate,
    eval,
    semantic_tree,
    click,
    fill,
    scroll,
    waitForSelector,
    hover,
    press,
    selectOption,
    setChecked,
    findElement,
};

const tool_map = std.StaticStringMap(ToolAction).initComptime(.{
    .{ "goto", .goto },
    .{ "navigate", .navigate },
    .{ "markdown", .markdown },
    .{ "links", .links },
    .{ "nodeDetails", .nodeDetails },
    .{ "interactiveElements", .interactiveElements },
    .{ "structuredData", .structuredData },
    .{ "detectForms", .detectForms },
    .{ "evaluate", .evaluate },
    .{ "eval", .eval },
    .{ "semantic_tree", .semantic_tree },
    .{ "click", .click },
    .{ "fill", .fill },
    .{ "scroll", .scroll },
    .{ "waitForSelector", .waitForSelector },
    .{ "hover", .hover },
    .{ "press", .press },
    .{ "selectOption", .selectOption },
    .{ "setChecked", .setChecked },
    .{ "findElement", .findElement },
});

pub fn handleCall(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null or req.id == null) {
        return server.sendError(req.id orelse .{ .integer = -1 }, .InvalidParams, "Missing params");
    }

    const CallParams = struct {
        name: []const u8,
        arguments: ?std.json.Value = null,
    };

    const call_params = std.json.parseFromValueLeaky(CallParams, arena, req.params.?, .{ .ignore_unknown_fields = true }) catch {
        return server.sendError(req.id.?, .InvalidParams, "Invalid params");
    };

    const action = tool_map.get(call_params.name) orelse {
        return server.sendError(req.id.?, .MethodNotFound, "Tool not found");
    };

    switch (action) {
        .goto, .navigate => try handleGoto(server, arena, req.id.?, call_params.arguments),
        .markdown => try handleMarkdown(server, arena, req.id.?, call_params.arguments),
        .links => try handleLinks(server, arena, req.id.?, call_params.arguments),
        .nodeDetails => try handleNodeDetails(server, arena, req.id.?, call_params.arguments),
        .interactiveElements => try handleInteractiveElements(server, arena, req.id.?, call_params.arguments),
        .structuredData => try handleStructuredData(server, arena, req.id.?, call_params.arguments),
        .detectForms => try handleDetectForms(server, arena, req.id.?, call_params.arguments),
        .eval, .evaluate => try handleEvaluate(server, arena, req.id.?, call_params.arguments),
        .semantic_tree => try handleSemanticTree(server, arena, req.id.?, call_params.arguments),
        .click => try handleClick(server, arena, req.id.?, call_params.arguments),
        .fill => try handleFill(server, arena, req.id.?, call_params.arguments),
        .scroll => try handleScroll(server, arena, req.id.?, call_params.arguments),
        .waitForSelector => try handleWaitForSelector(server, arena, req.id.?, call_params.arguments),
        .hover => try handleHover(server, arena, req.id.?, call_params.arguments),
        .press => try handlePress(server, arena, req.id.?, call_params.arguments),
        .selectOption => try handleSelectOption(server, arena, req.id.?, call_params.arguments),
        .setChecked => try handleSetChecked(server, arena, req.id.?, call_params.arguments),
        .findElement => try handleFindElement(server, arena, req.id.?, call_params.arguments),
    }
}

fn handleGoto(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgs(GotoParams, arena, arguments, server, id, "goto");
    try performGoto(server, args.url, id, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent([]const u8){.{ .text = "Navigated successfully." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleMarkdown(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{ .frame = frame, .action = .markdown },
    }};
    server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content }) catch {
        return server.sendError(id, .InternalError, "Failed to serialize markdown content");
    };
}

fn handleLinks(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{ .frame = frame, .action = .links },
    }};
    server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content }) catch {
        return server.sendError(id, .InternalError, "Failed to serialize links content");
    };
}

fn handleSemanticTree(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const TreeParams = struct {
        url: ?[:0]const u8 = null,
        backendNodeId: ?u32 = null,
        maxDepth: ?u32 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = try parseArgsOrDefault(TreeParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{
            .frame = frame,
            .action = .semantic_tree,
            .registry = &server.node_registry,
            .arena = arena,
            .backendNodeId = args.backendNodeId,
            .maxDepth = args.maxDepth,
        },
    }};
    server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content }) catch {
        return server.sendError(id, .InternalError, "Failed to serialize semantic tree content");
    };
}

fn handleNodeDetails(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "nodeDetails");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    const details = lp.SemanticTree.getNodeDetails(arena, resolved.node, &server.node_registry, resolved.frame) catch {
        return server.sendError(id, .InternalError, "Failed to get node details");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(&details, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleInteractiveElements(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const elements = lp.interactive.collectInteractiveElements(frame.document.asNode(), arena, frame) catch |err| {
        log.err(.mcp, "elements collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect interactive elements");
    };

    lp.interactive.registerNodes(elements, &server.node_registry) catch |err| {
        log.err(.mcp, "node registration failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to register element nodes");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(elements, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleStructuredData(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const data = lp.structured_data.collectStructuredData(frame.document.asNode(), arena, frame) catch |err| {
        log.err(.mcp, "struct data collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect structured data");
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(data, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleDetectForms(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgsOrDefault(UrlParams, arena, arguments, server, id);
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    const forms_data = lp.forms.collectForms(arena, frame.document.asNode(), frame) catch |err| {
        log.err(.mcp, "form collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect forms");
    };

    lp.forms.registerNodes(forms_data, &server.node_registry) catch |err| {
        log.err(.mcp, "form node registration failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to register form nodes");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(forms_data, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleEvaluate(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArgs(EvaluateParams, arena, arguments, server, id, "evaluate");
    const frame = try ensurePage(server, id, args.url, args.timeout, args.waitUntil);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(args.script, null) catch |err| {
        const caught = try_catch.caughtOrError(arena, err);
        var aw: std.Io.Writer.Allocating = .init(arena);
        try caught.format(&aw.writer);

        const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
        return server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content, .isError = true });
    };

    const str_result = js_result.toStringSliceWithAlloc(arena) catch "undefined";

    const content = [_]protocol.TextContent([]const u8){.{ .text = str_result }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleClick(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const ClickParams = struct {
        backendNodeId: CDPNode.Id,
    };
    const args = try parseArgs(ClickParams, arena, arguments, server, id, "click");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    lp.actions.click(resolved.node, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an HTML element");
        }
        return server.sendError(id, .InternalError, "Failed to click element");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Clicked element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleFill(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const FillParams = struct {
        backendNodeId: CDPNode.Id,
        text: []const u8,
    };
    const args = try parseArgs(FillParams, arena, arguments, server, id, "fill");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    lp.actions.fill(resolved.node, args.text, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an input, textarea or select");
        }
        return server.sendError(id, .InternalError, "Failed to fill element");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Filled element (backendNodeId: {d}) with \"{s}\". Page url: {s}, title: {s}", .{
        args.backendNodeId,
        args.text,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleScroll(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const ScrollParams = struct {
        backendNodeId: ?CDPNode.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = try parseArgs(ScrollParams, arena, arguments, server, id, "scroll");

    const frame = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = server.node_registry.lookup_by_id.get(node_id) orelse {
            return server.sendError(id, .InvalidParams, "Node not found");
        };
        target_node = node.dom;
    }

    lp.actions.scroll(target_node, args.x, args.y, frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an element");
        }
        return server.sendError(id, .InternalError, "Failed to scroll");
    };

    const page_title = frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Scrolled to x: {d}, y: {d}. Page url: {s}, title: {s}", .{
        args.x orelse 0,
        args.y orelse 0,
        frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleWaitForSelector(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const WaitParams = struct {
        selector: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = try parseArgs(WaitParams, arena, arguments, server, id, "waitForSelector");

    _ = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    const timeout_ms = args.timeout orelse 5000;

    const node = lp.actions.waitForSelector(args.selector, timeout_ms, server.session) catch |err| {
        if (err == error.InvalidSelector) {
            return server.sendError(id, .InvalidParams, "Invalid selector");
        } else if (err == error.Timeout) {
            return server.sendError(id, .InternalError, "Timeout waiting for selector");
        }
        return server.sendError(id, .InternalError, "Failed waiting for selector");
    };

    const registered = try server.node_registry.register(node);
    const msg = std.fmt.allocPrint(arena, "Element found. backendNodeId: {d}", .{registered.id}) catch "Element found.";

    const content = [_]protocol.TextContent([]const u8){.{ .text = msg }};
    return server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleHover(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "hover");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    lp.actions.hover(resolved.node, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an HTML element");
        }
        return server.sendError(id, .InternalError, "Failed to hover element");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Hovered element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handlePress(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        key: []const u8,
        backendNodeId: ?CDPNode.Id = null,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "press");

    const frame = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = server.node_registry.lookup_by_id.get(node_id) orelse {
            return server.sendError(id, .InvalidParams, "Node not found");
        };
        target_node = node.dom;
    }

    lp.actions.press(target_node, args.key, frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not an HTML element");
        }
        return server.sendError(id, .InternalError, "Failed to press key");
    };

    const page_title = frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Pressed key '{s}'. Page url: {s}, title: {s}", .{
        args.key,
        frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleSelectOption(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
        value: []const u8,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "selectOption");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    lp.actions.selectOption(resolved.node, args.value, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not a <select> element");
        }
        return server.sendError(id, .InternalError, "Failed to select option");
    };

    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Selected option '{s}' (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.value,
        args.backendNodeId,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleSetChecked(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        backendNodeId: CDPNode.Id,
        checked: bool,
    };
    const args = try parseArgs(Params, arena, arguments, server, id, "setChecked");
    const resolved = try resolveNodeAndPage(server, id, args.backendNodeId);

    lp.actions.setChecked(resolved.node, args.checked, resolved.frame) catch |err| {
        if (err == error.InvalidNodeType) {
            return server.sendError(id, .InvalidParams, "Node is not a checkbox or radio input");
        }
        return server.sendError(id, .InternalError, "Failed to set checked state");
    };

    const state_str = if (args.checked) "checked" else "unchecked";
    const page_title = resolved.frame.getTitle() catch null;
    const result_text = try std.fmt.allocPrint(arena, "Set element (backendNodeId: {d}) to {s}. Page url: {s}, title: {s}", .{
        args.backendNodeId,
        state_str,
        resolved.frame.url,
        page_title orelse "(none)",
    });
    const content = [_]protocol.TextContent([]const u8){.{ .text = result_text }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleFindElement(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        role: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments, server, id);

    if (args.role == null and args.name == null) {
        return server.sendError(id, .InvalidParams, "At least one of 'role' or 'name' must be provided");
    }

    const frame = server.session.currentFrame() orelse {
        return server.sendError(id, .FrameNotLoaded, "Frame not loaded");
    };

    const elements = lp.interactive.collectInteractiveElements(frame.document.asNode(), arena, frame) catch |err| {
        log.err(.mcp, "elements collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect interactive elements");
    };

    var matches: std.ArrayList(lp.interactive.InteractiveElement) = .empty;
    for (elements) |el| {
        if (args.role) |role| {
            const el_role = el.role orelse continue;
            if (!std.ascii.eqlIgnoreCase(el_role, role)) continue;
        }
        if (args.name) |name| {
            const el_name = el.name orelse continue;
            if (!containsIgnoreCase(el_name, name)) continue;
        }
        try matches.append(arena, el);
    }

    const matched = try matches.toOwnedSlice(arena);
    lp.interactive.registerNodes(matched, &server.node_registry) catch |err| {
        log.err(.mcp, "node registration failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to register element nodes");
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(matched, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

const NodeAndPage = struct { node: *DOMNode, frame: *lp.Frame };

fn resolveNodeAndPage(server: *Server, id: std.json.Value, node_id: CDPNode.Id) !NodeAndPage {
    const frame = server.session.currentFrame() orelse {
        try server.sendError(id, .FrameNotLoaded, "Frame not loaded");
        return error.FrameNotLoaded;
    };
    const node = server.node_registry.lookup_by_id.get(node_id) orelse {
        try server.sendError(id, .InvalidParams, "Node not found");
        return error.InvalidParams;
    };
    return .{ .node = node.dom, .frame = frame };
}

fn ensurePage(server: *Server, id: std.json.Value, url: ?[:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) !*lp.Frame {
    if (url) |u| {
        try performGoto(server, u, id, timeout, waitUntil);
    }
    return server.session.currentFrame() orelse {
        try server.sendError(id, .FrameNotLoaded, "Frame not loaded");
        return error.FrameNotLoaded;
    };
}

/// Parses JSON arguments into a given struct type `T`.
/// If the arguments are missing, it returns a default-initialized `T` (e.g., `.{}`).
/// If the arguments are present but invalid, it sends an MCP error response and returns `error.InvalidParams`.
/// Use this for tools where all arguments are optional.
fn parseArgsOrDefault(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value, server: *Server, id: std.json.Value) !T {
    const args_raw = arguments orelse return .{};
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch {
        try server.sendError(id, .InvalidParams, "Invalid arguments");
        return error.InvalidParams;
    };
}

/// Parses JSON arguments into a given struct type `T`.
/// If the arguments are missing or invalid, it automatically sends an MCP error response to the client
/// and returns an `error.InvalidParams`.
/// Use this for tools that require strict validation or mandatory arguments.
fn parseArgs(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value, server: *Server, id: std.json.Value, tool_name: []const u8) !T {
    const args_raw = arguments orelse {
        try server.sendError(id, .InvalidParams, "Missing arguments");
        return error.InvalidParams;
    };
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch {
        const msg = std.fmt.allocPrint(arena, "Invalid arguments for {s}", .{tool_name}) catch "Invalid arguments";
        try server.sendError(id, .InvalidParams, msg);
        return error.InvalidParams;
    };
}

fn performGoto(server: *Server, url: [:0]const u8, id: std.json.Value, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) !void {
    const session = server.session;
    if (session.page != null) {
        session.removePage();
    }
    const frame = session.createPage() catch {
        try server.sendError(id, .InternalError, "Failed to create page");
        return error.NavigationFailed;
    };
    frame.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch {
        try server.sendError(id, .InternalError, "Internal error during navigation");
        return error.NavigationFailed;
    };

    var runner = session.runner(.{}) catch {
        try server.sendError(id, .InternalError, "Failed to start page runner");
        return error.NavigationFailed;
    };
    runner.wait(.{
        .ms = timeout orelse 10000,
        .until = waitUntil orelse .done,
    }) catch {
        try server.sendError(id, .InternalError, "Error waiting for page load");
        return error.NavigationFailed;
    };
}

const router = @import("router.zig");
const testing = @import("../testing.zig");

test "MCP - evaluate error reporting" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage("about:blank", &out.writer);
    defer server.deinit();

    // Call evaluate with a script that throws an error
    const msg =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "evaluate",
        \\    "arguments": {
        \\      "script": "throw new Error('test error')"
        \\    }
        \\  }
        \\}
    ;

    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{
        .isError = true,
        .content = &.{.{ .type = "text" }},
    } }, out.written());
}

test "MCP - Actions: click, fill, scroll, hover, press, selectOption, setChecked" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    const frame = server.session.currentFrame().?;

    {
        // Test Click
        const btn = frame.document.getElementById("btn", frame).?.asNode();
        const btn_id = (try server.node_registry.register(btn)).id;
        var btn_id_buf: [12]u8 = undefined;
        const btn_id_str = std.fmt.bufPrint(&btn_id_buf, "{d}", .{btn_id}) catch unreachable;
        const click_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":", btn_id_str, "}}}" });
        try router.handleMessage(server, aa, click_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Clicked element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Page url: http://localhost:9582/src/browser/tests/mcp_actions.html") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Fill Input
        const inp = frame.document.getElementById("inp", frame).?.asNode();
        const inp_id = (try server.node_registry.register(inp)).id;
        var inp_id_buf: [12]u8 = undefined;
        const inp_id_str = std.fmt.bufPrint(&inp_id_buf, "{d}", .{inp_id}) catch unreachable;
        const fill_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", inp_id_str, ",\"text\":\"hello\"}}}" });
        try router.handleMessage(server, aa, fill_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"hello\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Fill Select
        const sel = frame.document.getElementById("sel", frame).?.asNode();
        const sel_id = (try server.node_registry.register(sel)).id;
        var sel_id_buf: [12]u8 = undefined;
        const sel_id_str = std.fmt.bufPrint(&sel_id_buf, "{d}", .{sel_id}) catch unreachable;
        const fill_sel_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", sel_id_str, ",\"text\":\"opt2\"}}}" });
        try router.handleMessage(server, aa, fill_sel_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Filled element") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "with \\\"opt2\\\"") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Scroll
        const scrollbox = frame.document.getElementById("scrollbox", frame).?.asNode();
        const scrollbox_id = (try server.node_registry.register(scrollbox)).id;
        var scroll_id_buf: [12]u8 = undefined;
        const scroll_id_str = std.fmt.bufPrint(&scroll_id_buf, "{d}", .{scrollbox_id}) catch unreachable;
        const scroll_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"scroll\",\"arguments\":{\"backendNodeId\":", scroll_id_str, ",\"y\":50}}}" });
        try router.handleMessage(server, aa, scroll_msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Scrolled to x: 0, y: 50") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Hover
        const el = frame.document.getElementById("hoverTarget", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"hover\",\"arguments\":{\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Hovered element") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test Press
        const el = frame.document.getElementById("keyTarget", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"press\",\"arguments\":{\"key\":\"Enter\",\"backendNodeId\":", id_str, "}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Pressed key") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SelectOption
        const el = frame.document.getElementById("sel2", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"selectOption\",\"arguments\":{\"backendNodeId\":", id_str, ",\"value\":\"b\"}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Selected option") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SetChecked (checkbox)
        const el = frame.document.getElementById("chk", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    {
        // Test SetChecked (radio)
        const el = frame.document.getElementById("rad", frame).?.asNode();
        const el_id = (try server.node_registry.register(el)).id;
        var id_buf: [12]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{el_id}) catch unreachable;
        const msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"setChecked\",\"arguments\":{\"backendNodeId\":", id_str, ",\"checked\":true}}}" });
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "checked") != null);
        out.clearRetainingCapacity();
    }

    // Evaluate JS assertions for all actions
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const result = try ls.local.exec(
        \\ window.clicked === true && window.inputVal === 'hello' &&
        \\ window.changed === true && window.selChanged === 'opt2' &&
        \\ window.scrolled === true &&
        \\ window.hovered === true &&
        \\ window.keyPressed === 'Enter' && window.keyReleased === 'Enter' &&
        \\ window.sel2Changed === 'b' &&
        \\ window.chkClicked === true && window.chkChanged === true &&
        \\ window.radClicked === true && window.radChanged === true
    , null);

    try testing.expect(result.isTrue());
}

test "MCP - findElement" {
    defer testing.reset();
    const aa = testing.arena_allocator;

    var out: std.io.Writer.Allocating = .init(aa);
    const server = try testLoadPage("http://localhost:9582/src/browser/tests/mcp_actions.html", &out.writer);
    defer server.deinit();

    {
        // Find by role
        const msg =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"button"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        // Find by name (case-insensitive substring)
        const msg =
            \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"findElement","arguments":{"name":"click"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "Click Me") != null);
        out.clearRetainingCapacity();
    }

    {
        // Find with no matches
        const msg =
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"findElement","arguments":{"role":"slider"}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "[]") != null);
        out.clearRetainingCapacity();
    }

    {
        // Error: no params provided
        const msg =
            \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"findElement","arguments":{}}}
        ;
        try router.handleMessage(server, aa, msg);
        try testing.expect(std.mem.indexOf(u8, out.written(), "error") != null);
        out.clearRetainingCapacity();
    }
}

test "MCP - waitForSelector: existing element" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector on an element that already exists returns immediately
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#existing","timeout":2000}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{ .content = &.{.{ .type = "text" }} } }, out.written());
}

test "MCP - waitForSelector: delayed element" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector on an element added after 200ms via setTimeout
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#delayed","timeout":5000}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);

    try testing.expectJson(.{ .id = 1, .result = .{ .content = &.{.{ .type = "text" }} } }, out.written());
}

test "MCP - waitForSelector: timeout" {
    defer testing.reset();
    var out: std.io.Writer.Allocating = .init(testing.arena_allocator);
    const server = try testLoadPage(
        "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html",
        &out.writer,
    );
    defer server.deinit();

    // waitForSelector with a short timeout on a non-existent element should error
    const msg =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waitForSelector","arguments":{"selector":"#nonexistent","timeout":100}}}
    ;
    try router.handleMessage(server, testing.arena_allocator, msg);
    try testing.expectJson(.{
        .id = 1,
        .@"error" = struct {}{},
    }, out.written());
}

fn testLoadPage(url: [:0]const u8, writer: *std.Io.Writer) !*Server {
    var server = try Server.init(testing.allocator, testing.test_app, writer);
    errdefer server.deinit();

    const frame = try server.session.createPage();
    try frame.navigate(url, .{});

    var runner = try server.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });
    return server;
}
