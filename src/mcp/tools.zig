const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;
const js = lp.js;

const Element = @import("../browser/webapi/Element.zig");
const Selector = @import("../browser/webapi/selector/Selector.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");

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
        .name = "search",
        .description = "Use a search engine to look for specific words, terms, sentences. The search page will then be loaded in memory.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "text": { "type": "string", "description": "The text to search for, must be a valid search query." }
            \\  },
            \\  "required": ["text"]
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
        .name = "over",
        .description = "Used to indicate that the task is over and give the final answer if there is any. This is the last tool to be called in a task.",
        .inputSchema = protocol.minify(
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "result": { "type": "string", "description": "The final result of the task." }
            \\  },
            \\  "required": ["result"]
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

const SearchParams = struct {
    text: [:0]const u8,
};

const EvaluateParams = struct {
    script: [:0]const u8,
    url: ?[:0]const u8 = null,
};

const OverParams = struct {
    result: [:0]const u8,
};

const ToolStreamingText = struct {
    server: *Server,
    action: enum { markdown, links },

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        var escaped = protocol.JsonEscapingWriter.init(jw.writer);
        const w = &escaped.writer;
        switch (self.action) {
            .markdown => lp.markdown.dump(self.server.page.document.asNode(), .{}, w, self.server.page) catch |err| {
                log.err(.mcp, "markdown dump failed", .{ .err = err });
            },
            .links => {
                if (Selector.querySelectorAll(self.server.page.document.asNode(), "a[href]", self.server.page)) |list| {
                    defer list.deinit(self.server.page);
                    var first = true;
                    for (list._nodes) |node| {
                        if (node.is(Element.Html.Anchor)) |anchor| {
                            const href = anchor.getHref(self.server.page) catch |err| {
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
        }
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }
};

const ToolAction = enum {
    goto,
    navigate,
    search,
    markdown,
    links,
    evaluate,
    over,
};

const tool_map = std.StaticStringMap(ToolAction).initComptime(.{
    .{ "goto", .goto },
    .{ "navigate", .navigate },
    .{ "search", .search },
    .{ "markdown", .markdown },
    .{ "links", .links },
    .{ "evaluate", .evaluate },
    .{ "over", .over },
});

pub fn handleCall(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null) {
        return server.sendError(req.id.?, .InvalidParams, "Missing params");
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
        .search => try handleSearch(server, arena, req.id.?, call_params.arguments),
        .markdown => try handleMarkdown(server, arena, req.id.?, call_params.arguments),
        .links => try handleLinks(server, arena, req.id.?, call_params.arguments),
        .evaluate => try handleEvaluate(server, arena, req.id.?, call_params.arguments),
        .over => try handleOver(server, arena, req.id.?, call_params.arguments),
    }
}

fn handleGoto(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArguments(GotoParams, arena, arguments, server, id, "goto");
    try performGoto(server, args.url, id);

    const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Navigated successfully." }};
    try server.sendResult(id, .{ .content = &content });
}

fn handleSearch(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArguments(SearchParams, arena, arguments, server, id, "search");

    const component: std.Uri.Component = .{ .raw = args.text };
    var url_aw = std.Io.Writer.Allocating.init(arena);
    component.formatQuery(&url_aw.writer) catch {
        return server.sendError(id, .InternalError, "Internal error formatting query");
    };
    const url = std.fmt.allocPrintSentinel(arena, "https://duckduckgo.com/?q={s}", .{url_aw.written()}, 0) catch {
        return server.sendError(id, .InternalError, "Internal error formatting URL");
    };

    try performGoto(server, url, id);

    const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Search performed successfully." }};
    try server.sendResult(id, .{ .content = &content });
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

    const result = struct {
        content: []const struct { type: []const u8, text: ToolStreamingText },
    }{
        .content = &.{.{
            .type = "text",
            .text = .{ .server = server, .action = .markdown },
        }},
    };
    try server.sendResult(id, result);
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

    const result = struct {
        content: []const struct { type: []const u8, text: ToolStreamingText },
    }{
        .content = &.{.{
            .type = "text",
            .text = .{ .server = server, .action = .links },
        }},
    };
    try server.sendResult(id, result);
}

fn handleEvaluate(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArguments(EvaluateParams, arena, arguments, server, id, "evaluate");

    if (args.url) |url| {
        try performGoto(server, url, id);
    }

    var ls: js.Local.Scope = undefined;
    server.page.js.localScope(&ls);
    defer ls.deinit();

    const js_result = ls.local.compileAndRun(args.script, null) catch {
        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Script evaluation failed." }};
        return server.sendResult(id, .{ .content = &content, .isError = true });
    };

    const str_result = js_result.toStringSliceWithAlloc(arena) catch "undefined";

    const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = str_result }};
    try server.sendResult(id, .{ .content = &content });
}

fn handleOver(server: *Server, arena: std.mem.Allocator, id: std.json.Value, arguments: ?std.json.Value) !void {
    const args = try parseArguments(OverParams, arena, arguments, server, id, "over");

    const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = args.result }};
    try server.sendResult(id, .{ .content = &content });
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
    _ = server.page.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch {
        try server.sendError(id, .InternalError, "Internal error during navigation");
        return error.NavigationFailed;
    };

    _ = server.session.wait(5000);
}

const testing = @import("../testing.zig");
