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
                    defer list.deinit(self.page);
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
    evaluate,
    semantic_tree,
};

const tool_map = std.StaticStringMap(ToolAction).initComptime(.{
    .{ "goto", .goto },
    .{ "navigate", .navigate },
    .{ "markdown", .markdown },
    .{ "links", .links },
    .{ "evaluate", .evaluate },
    .{ "semantic_tree", .semantic_tree },
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
        .evaluate => try handleEvaluate(server, arena, req.id.?, call_params.arguments),
        .semantic_tree => try handleSemanticTree(server, arena, req.id.?, call_params.arguments),
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
