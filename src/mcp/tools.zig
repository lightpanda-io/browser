const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;
const js = lp.js;

const Element = @import("../browser/webapi/Element.zig");
const Selector = @import("../browser/webapi/selector/Selector.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const CDPNode = @import("../cdp/Node.zig");

pub const tool_list = [_]protocol.Tool{
    .{
        .name = "goto",
        .description = "Navigate to a specified URL and load the page in memory so it can be reused later for info extraction.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "url": { "type": "string", "description": "The URL to navigate to, must be a valid URL." }
            \\  },
            \\  "required": ["url"]
            \\}
        ),
    },
    .{
        .name = "markdown",
        .description = "Get the page content in markdown format. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "url": { "type": "string", "description": "Optional URL to navigate to before fetching markdown." }
            \\  }
            \\}
        ),
    },
    .{
        .name = "links",
        .description = "Extract all links in the opened page. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "url": { "type": "string", "description": "Optional URL to navigate to before extracting links." }
            \\  }
            \\}
        ),
    },
    .{
        .name = "evaluate",
        .description = "Evaluate JavaScript in the current page context. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "script": { "type": "string" },
            \\    "url": { "type": "string", "description": "Optional URL to navigate to before evaluating." }
            \\  },
            \\  "required": ["script"]
            \\}
        ),
    },
    .{
        .name = "semantic_tree",
        .description = "Get the page content as a simplified semantic DOM tree for AI reasoning. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "url": { "type": "string", "description": "Optional URL to navigate to before fetching the semantic tree." }
            \\  }
            \\}
        ),
    },
    .{
        .name = "interactiveElements",
        .description = "Extract interactive elements from the opened page. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "url": { "type": "string", "description": "Optional URL to navigate to before extracting interactive elements." }
            \\  }
            \\}
        ),
    },
    .{
        .name = "structuredData",
        .description = "Extract structured data (like JSON-LD, OpenGraph, etc) from the opened page. If a url is provided, it navigates to that url first.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "url": { "type": "string", "description": "Optional URL to navigate to before extracting structured data." }
            \\  }
            \\}
        ),
    },
    .{
        .name = "click",
        .description = "Click on an interactive element.",
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
        .description = "Fill text into an input element.",
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
        .description = "Scroll the page or a specific element.",
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
};

pub fn handleList(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    _ = arena;
    try server.sendResult(req.id.?, .{ .tools = &tool_list });
}

const GotoParams = struct {
    url: [:0]const u8,
};

const EvaluateParams = struct {
    script: [:0]const u8,
    url: ?[:0]const u8 = null,
};

const ToolStreamingText = struct {
    page: *lp.Page,
    action: enum { markdown, links, semantic_tree },
    registry: ?*CDPNode.Registry = null,
    arena: ?std.mem.Allocator = null,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        var escaped: protocol.JsonEscapingWriter = .init(jw.writer);
        const w = &escaped.writer;

        switch (self.action) {
            .markdown => lp.markdown.dump(self.page.document.asNode(), .{}, w, self.page) catch |err| {
                log.err(.mcp, "markdown dump failed", .{ .err = err });
            },
            .links => {
                if (Selector.querySelectorAll(self.page.document.asNode(), "a[href]", self.page)) |list| {
                    defer list.deinit(self.page._session);

                    var first = true;
                    for (list._nodes) |node| {
                        if (node.is(Element.Html.Anchor)) |anchor| {
                            const href = anchor.getHref(self.page) catch |err| {
                                log.err(.mcp, "resolve href failed", .{ .err = err });
                                continue;
                            };

                            if (href.len > 0) {
                                if (!first) try w.writeByte('\n');
                                try w.writeAll(href);
                                first = false;
                            }
                        }
                    }
                } else |err| {
                    log.err(.mcp, "query links failed", .{ .err = err });
                }
            },
            .semantic_tree => {
                const st = lp.SemanticTree{
                    .dom_node = self.page.document.asNode(),
                    .registry = self.registry.?,
                    .page = self.page,
                    .arena = self.arena.?,
                    .prune = true,
                };

                st.textStringify(w) catch |err| {
                    log.err(.mcp, "semantic tree dump failed", .{ .err = err });
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
    interactiveElements,
    structuredData,
    evaluate,
    semantic_tree,
    click,
    fill,
    scroll,
};

const tool_map = std.StaticStringMap(ToolAction).initComptime(.{
    .{ "goto", .goto },
    .{ "navigate", .navigate },
    .{ "markdown", .markdown },
    .{ "links", .links },
    .{ "interactiveElements", .interactiveElements },
    .{ "structuredData", .structuredData },
    .{ "evaluate", .evaluate },
    .{ "semantic_tree", .semantic_tree },
    .{ "click", .click },
    .{ "fill", .fill },
    .{ "scroll", .scroll },
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
        .interactiveElements => try handleInteractiveElements(server, arena, req.id.?, call_params.arguments),
        .structuredData => try handleStructuredData(server, arena, req.id.?, call_params.arguments),
        .evaluate => try handleEvaluate(server, arena, req.id.?, call_params.arguments),
        .semantic_tree => try handleSemanticTree(server, arena, req.id.?, call_params.arguments),
        .click => try handleClick(server, arena, req.id.?, call_params.arguments),
        .fill => try handleFill(server, arena, req.id.?, call_params.arguments),
        .scroll => try handleScroll(server, arena, req.id.?, call_params.arguments),
    }
}

fn handleGoto(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArguments(GotoParams, arena, arguments, server, id, "goto");
    try performGoto(server, args.url, id);

    const content = [_]protocol.TextContent([]const u8){.{ .text = "Navigated successfully." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleMarkdown(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const MarkdownParams = struct {
        url: ?[:0]const u8 = null,
    };
    if (arguments) |args_raw| {
        if (std.json.parseFromValueLeaky(MarkdownParams, arena, args_raw, .{ .ignore_unknown_fields = true })) |args| {
            if (args.url) |u| {
                try performGoto(server, u, id);
            }
        } else |_| {}
    }
    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{ .page = page, .action = .markdown },
    }};
    try server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content });
}

fn handleLinks(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const LinksParams = struct {
        url: ?[:0]const u8 = null,
    };
    if (arguments) |args_raw| {
        if (std.json.parseFromValueLeaky(LinksParams, arena, args_raw, .{ .ignore_unknown_fields = true })) |args| {
            if (args.url) |u| {
                try performGoto(server, u, id);
            }
        } else |_| {}
    }
    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{ .page = page, .action = .links },
    }};
    try server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content });
}

fn handleSemanticTree(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const TreeParams = struct {
        url: ?[:0]const u8 = null,
    };
    if (arguments) |args_raw| {
        if (std.json.parseFromValueLeaky(TreeParams, arena, args_raw, .{ .ignore_unknown_fields = true })) |args| {
            if (args.url) |u| {
                try performGoto(server, u, id);
            }
        } else |_| {}
    }
    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const content = [_]protocol.TextContent(ToolStreamingText){.{
        .text = .{ .page = page, .action = .semantic_tree, .registry = &server.node_registry, .arena = arena },
    }};
    try server.sendResult(id, protocol.CallToolResult(ToolStreamingText){ .content = &content });
}

fn handleInteractiveElements(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        url: ?[:0]const u8 = null,
    };
    if (arguments) |args_raw| {
        if (std.json.parseFromValueLeaky(Params, arena, args_raw, .{ .ignore_unknown_fields = true })) |args| {
            if (args.url) |u| {
                try performGoto(server, u, id);
            }
        } else |_| {}
    }
    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const elements = lp.interactive.collectInteractiveElements(page.document.asNode(), arena, page) catch |err| {
        log.err(.mcp, "elements collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect interactive elements");
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(elements, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleStructuredData(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const Params = struct {
        url: ?[:0]const u8 = null,
    };
    if (arguments) |args_raw| {
        if (std.json.parseFromValueLeaky(Params, arena, args_raw, .{ .ignore_unknown_fields = true })) |args| {
            if (args.url) |u| {
                try performGoto(server, u, id);
            }
        } else |_| {}
    }
    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const data = lp.structured_data.collectStructuredData(page.document.asNode(), arena, page) catch |err| {
        log.err(.mcp, "struct data collection failed", .{ .err = err });
        return server.sendError(id, .InternalError, "Failed to collect structured data");
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(data, .{}, &aw.writer);

    const content = [_]protocol.TextContent([]const u8){.{ .text = aw.written() }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleEvaluate(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArguments(EvaluateParams, arena, arguments, server, id, "evaluate");

    if (args.url) |url| {
        try performGoto(server, url, id);
    }
    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
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
    const args = try parseArguments(ClickParams, arena, arguments, server, id, "click");

    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const node = server.node_registry.lookup_by_id.get(args.backendNodeId) orelse {
        return server.sendError(id, .InvalidParams, "Node not found");
    };

    if (node.dom.is(Element)) |el| {
        if (el.is(Element.Html)) |html_el| {
            html_el.click(page) catch |err| {
                log.err(.mcp, "click failed", .{ .err = err });
                return server.sendError(id, .InternalError, "Failed to click element");
            };
        } else {
            return server.sendError(id, .InvalidParams, "Node is not an HTML element");
        }
    } else {
        return server.sendError(id, .InvalidParams, "Node is not an element");
    }

    const content = [_]protocol.TextContent([]const u8){.{ .text = "Clicked successfully." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleFill(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const FillParams = struct {
        backendNodeId: CDPNode.Id,
        text: []const u8,
    };
    const args = try parseArguments(FillParams, arena, arguments, server, id, "fill");

    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const node = server.node_registry.lookup_by_id.get(args.backendNodeId) orelse {
        return server.sendError(id, .InvalidParams, "Node not found");
    };

    if (node.dom.is(Element)) |el| {
        if (el.is(Element.Html.Input)) |input| {
            input.setValue(args.text, page) catch |err| {
                log.err(.mcp, "fill input failed", .{ .err = err });
                return server.sendError(id, .InternalError, "Failed to fill input");
            };
        } else if (el.is(Element.Html.TextArea)) |textarea| {
            textarea.setValue(args.text, page) catch |err| {
                log.err(.mcp, "fill textarea failed", .{ .err = err });
                return server.sendError(id, .InternalError, "Failed to fill textarea");
            };
        } else if (el.is(Element.Html.Select)) |select| {
            select.setValue(args.text, page) catch |err| {
                log.err(.mcp, "fill select failed", .{ .err = err });
                return server.sendError(id, .InternalError, "Failed to fill select");
            };
        } else {
            return server.sendError(id, .InvalidParams, "Node is not an input, textarea or select");
        }

        const Event = @import("../browser/webapi/Event.zig");
        const input_evt = try Event.initTrusted(comptime lp.String.wrap("input"), .{ .bubbles = true }, page);
        _ = page._event_manager.dispatch(el.asEventTarget(), input_evt) catch {};

        const change_evt = try Event.initTrusted(comptime lp.String.wrap("change"), .{ .bubbles = true }, page);
        _ = page._event_manager.dispatch(el.asEventTarget(), change_evt) catch {};
    } else {
        return server.sendError(id, .InvalidParams, "Node is not an element");
    }

    const content = [_]protocol.TextContent([]const u8){.{ .text = "Filled successfully." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn handleScroll(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const ScrollParams = struct {
        backendNodeId: ?CDPNode.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = try parseArguments(ScrollParams, arena, arguments, server, id, "scroll");

    const page = server.session.currentPage() orelse {
        return server.sendError(id, .PageNotLoaded, "Page not loaded");
    };

    const x = args.x orelse 0;
    const y = args.y orelse 0;

    if (args.backendNodeId) |node_id| {
        const node = server.node_registry.lookup_by_id.get(node_id) orelse {
            return server.sendError(id, .InvalidParams, "Node not found");
        };

        if (node.dom.is(Element)) |el| {
            if (args.x != null) {
                el.setScrollLeft(x, page) catch {};
            }
            if (args.y != null) {
                el.setScrollTop(y, page) catch {};
            }

            const Event = @import("../browser/webapi/Event.zig");
            const scroll_evt = try Event.initTrusted(comptime lp.String.wrap("scroll"), .{ .bubbles = true }, page);
            _ = page._event_manager.dispatch(el.asEventTarget(), scroll_evt) catch {};
        } else {
            return server.sendError(id, .InvalidParams, "Node is not an element");
        }
    } else {
        page.window.scrollTo(.{ .x = x }, y, page) catch |err| {
            log.err(.mcp, "scroll failed", .{ .err = err });
            return server.sendError(id, .InternalError, "Failed to scroll");
        };
    }

    const content = [_]protocol.TextContent([]const u8){.{ .text = "Scrolled successfully." }};
    try server.sendResult(id, protocol.CallToolResult([]const u8){ .content = &content });
}

fn parseArguments(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value, server: *Server, id: std.json.Value, tool_name: []const u8) !T {
    if (arguments == null) {
        try server.sendError(id, .InvalidParams, "Missing arguments");
        return error.InvalidParams;
    }
    return std.json.parseFromValueLeaky(T, arena, arguments.?, .{ .ignore_unknown_fields = true }) catch {
        const msg = std.fmt.allocPrint(arena, "Invalid arguments for {s}", .{tool_name}) catch "Invalid arguments";
        try server.sendError(id, .InvalidParams, msg);
        return error.InvalidParams;
    };
}

fn performGoto(server: *Server, url: [:0]const u8, id: std.json.Value) !void {
    const session = server.session;
    if (session.page != null) {
        session.removePage();
    }
    const page = try session.createPage();
    page.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch {
        try server.sendError(id, .InternalError, "Internal error during navigation");
        return error.NavigationFailed;
    };

    _ = server.session.wait(5000);
}

const testing = @import("../testing.zig");
const router = @import("router.zig");

test "MCP - evaluate error reporting" {
    defer testing.reset();
    const allocator = testing.allocator;
    const app = testing.test_app;

    var out_alloc: std.io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Server.init(allocator, app, &out_alloc.writer);
    defer server.deinit();
    _ = try server.session.createPage();

    const aa = testing.arena_allocator;

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

    try router.handleMessage(server, aa, msg);

    try testing.expectJson(
        \\{
        \\  "id": 1,
        \\  "result": {
        \\    "isError": true,
        \\    "content": [
        \\      { "type": "text" }
        \\    ]
        \\  }
        \\}
    , out_alloc.writer.buffered());
}

test "MCP - Actions: click, fill, scroll" {
    defer testing.reset();
    const allocator = testing.allocator;
    const app = testing.test_app;

    var out_alloc: std.io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Server.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    const aa = testing.arena_allocator;
    const page = try server.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try page.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    _ = server.session.wait(5000);

    // Test Click
    const btn = page.document.getElementById("btn", page).?.asNode();
    const btn_id = (try server.node_registry.register(btn)).id;
    var btn_id_buf: [12]u8 = undefined;
    const btn_id_str = std.fmt.bufPrint(&btn_id_buf, "{d}", .{btn_id}) catch unreachable;
    const click_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"backendNodeId\":", btn_id_str, "}}}" });
    try router.handleMessage(server, aa, click_msg);

    // Test Fill Input
    const inp = page.document.getElementById("inp", page).?.asNode();
    const inp_id = (try server.node_registry.register(inp)).id;
    var inp_id_buf: [12]u8 = undefined;
    const inp_id_str = std.fmt.bufPrint(&inp_id_buf, "{d}", .{inp_id}) catch unreachable;
    const fill_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", inp_id_str, ",\"text\":\"hello\"}}}" });
    try router.handleMessage(server, aa, fill_msg);

    // Test Fill Select
    const sel = page.document.getElementById("sel", page).?.asNode();
    const sel_id = (try server.node_registry.register(sel)).id;
    var sel_id_buf: [12]u8 = undefined;
    const sel_id_str = std.fmt.bufPrint(&sel_id_buf, "{d}", .{sel_id}) catch unreachable;
    const fill_sel_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"fill\",\"arguments\":{\"backendNodeId\":", sel_id_str, ",\"text\":\"opt2\"}}}" });
    try router.handleMessage(server, aa, fill_sel_msg);

    // Test Scroll
    const scrollbox = page.document.getElementById("scrollbox", page).?.asNode();
    const scrollbox_id = (try server.node_registry.register(scrollbox)).id;
    var scroll_id_buf: [12]u8 = undefined;
    const scroll_id_str = std.fmt.bufPrint(&scroll_id_buf, "{d}", .{scrollbox_id}) catch unreachable;
    const scroll_msg = try std.mem.concat(aa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"scroll\",\"arguments\":{\"backendNodeId\":", scroll_id_str, ",\"y\":50}}}" });
    try router.handleMessage(server, aa, scroll_msg);

    // Evaluate assertions
    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const result = try ls.local.compileAndRun("window.clicked === true && window.inputVal === 'hello' && window.changed === true && window.selChanged === 'opt2' && window.scrolled === true", null);

    try testing.expect(result.isTrue());
}
