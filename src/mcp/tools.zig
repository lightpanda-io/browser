const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;
const js = lp.js;

const Element = @import("../browser/webapi/Element.zig");
const Selector = @import("../browser/webapi/selector/Selector.zig");
const String = @import("../string.zig").String;
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");

pub fn handleList(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    const tools = [_]protocol.Tool{
        .{
            .name = "goto",
            .description = "Navigate to a specified URL and load the page in memory so it can be reused later for info extraction.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string", "description": "The URL to navigate to, must be a valid URL." }
                \\  },
                \\  "required": ["url"]
                \\}
            , .{}) catch unreachable,
        },
        .{
            .name = "search",
            .description = "Use a search engine to look for specific words, terms, sentences. The search page will then be loaded in memory.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "text": { "type": "string", "description": "The text to search for, must be a valid search query." }
                \\  },
                \\  "required": ["text"]
                \\}
            , .{}) catch unreachable,
        },
        .{
            .name = "markdown",
            .description = "Get the page content in markdown format. If a url is provided, it navigates to that url first.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before fetching markdown." }
                \\  }
                \\}
            , .{}) catch unreachable,
        },
        .{
            .name = "links",
            .description = "Extract all links in the opened page. If a url is provided, it navigates to that url first.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before extracting links." }
                \\  }
                \\}
            , .{}) catch unreachable,
        },
        .{
            .name = "evaluate",
            .description = "Evaluate JavaScript in the current page context. If a url is provided, it navigates to that url first.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "script": { "type": "string" },
                \\    "url": { "type": "string", "description": "Optional URL to navigate to before evaluating." }
                \\  },
                \\  "required": ["script"]
                \\}
            , .{}) catch unreachable,
        },
        .{
            .name = "over",
            .description = "Used to indicate that the task is over and give the final answer if there is any. This is the last tool to be called in a task.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "result": { "type": "string", "description": "The final result of the task." }
                \\  },
                \\  "required": ["result"]
                \\}
            , .{}) catch unreachable,
        },
    };

    const result = struct {
        tools: []const protocol.Tool,
    }{
        .tools = &tools,
    };

    try sendResult(server, req.id.?, result);
}

const GotoParams = struct {
    url: []const u8,
};

const SearchParams = struct {
    text: []const u8,
};

const EvaluateParams = struct {
    script: []const u8,
};

const OverParams = struct {
    result: []const u8,
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
            .markdown => try lp.markdown.dump(self.server.page.document.asNode(), .{}, w, self.server.page),
            .links => {
                const list = Selector.querySelectorAll(self.server.page.document.asNode(), "a[href]", self.server.page) catch |err| {
                    log.err(.mcp, "Error querying links: {s}", .{@errorName(err)});
                    return;
                };
                var first = true;
                for (list._nodes) |node| {
                    if (node.is(Element)) |el| {
                        if (el.getAttributeSafe(String.wrap("href"))) |href| {
                            if (!first) try w.writeByte('\n');
                            try w.writeAll(href);
                            first = false;
                        }
                    }
                }
            },
        }
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }
};

pub fn handleCall(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null) {
        return sendError(server, req.id.?, -32602, "Missing params");
    }

    const CallParams = struct {
        name: []const u8,
        arguments: ?std.json.Value = null,
    };

    const call_params = std.json.parseFromValueLeaky(CallParams, arena, req.params.?, .{ .ignore_unknown_fields = true }) catch {
        var aw: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(req.params.?, .{}, &aw.writer) catch {};
        const msg = std.fmt.allocPrint(arena, "Invalid params: {s}", .{aw.written()}) catch "Invalid params";
        return sendError(server, req.id.?, -32602, msg);
    };

    if (std.mem.eql(u8, call_params.name, "goto") or std.mem.eql(u8, call_params.name, "navigate")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id.?, -32602, "Missing arguments for goto");
        }
        const args = std.json.parseFromValueLeaky(GotoParams, arena, call_params.arguments.?, .{ .ignore_unknown_fields = true }) catch {
            return sendError(server, req.id.?, -32602, "Invalid arguments for goto");
        };

        performGoto(server, arena, args.url) catch {
            return sendError(server, req.id.?, -32603, "Internal error during navigation");
        };

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Navigated successfully." }};
        try sendResult(server, req.id.?, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "search")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id.?, -32602, "Missing arguments for search");
        }
        const args = std.json.parseFromValueLeaky(SearchParams, arena, call_params.arguments.?, .{ .ignore_unknown_fields = true }) catch {
            return sendError(server, req.id.?, -32602, "Invalid arguments for search");
        };

        const component: std.Uri.Component = .{ .raw = args.text };
        var url_aw = std.Io.Writer.Allocating.init(arena);
        component.formatQuery(&url_aw.writer) catch {
            return sendError(server, req.id.?, -32603, "Internal error formatting query");
        };
        const url = std.fmt.allocPrint(arena, "https://duckduckgo.com/?q={s}", .{url_aw.written()}) catch {
            return sendError(server, req.id.?, -32603, "Internal error formatting URL");
        };

        performGoto(server, arena, url) catch {
            return sendError(server, req.id.?, -32603, "Internal error during search navigation");
        };

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Search performed successfully." }};
        try sendResult(server, req.id.?, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "markdown")) {
        const MarkdownParams = struct {
            url: ?[]const u8 = null,
        };
        if (call_params.arguments) |args_raw| {
            if (std.json.parseFromValueLeaky(MarkdownParams, arena, args_raw, .{ .ignore_unknown_fields = true })) |args| {
                if (args.url) |u| {
                    performGoto(server, arena, u) catch {
                        return sendError(server, req.id.?, -32603, "Internal error during navigation");
                    };
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
        try sendResult(server, req.id.?, result);
    } else if (std.mem.eql(u8, call_params.name, "links")) {
        const LinksParams = struct {
            url: ?[]const u8 = null,
        };
        if (call_params.arguments) |args_raw| {
            if (std.json.parseFromValueLeaky(LinksParams, arena, args_raw, .{ .ignore_unknown_fields = true })) |args| {
                if (args.url) |u| {
                    performGoto(server, arena, u) catch {
                        return sendError(server, req.id.?, -32603, "Internal error during navigation");
                    };
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
        try sendResult(server, req.id.?, result);
    } else if (std.mem.eql(u8, call_params.name, "evaluate")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id.?, -32602, "Missing arguments for evaluate");
        }

        const EvaluateParamsEx = struct {
            script: []const u8,
            url: ?[]const u8 = null,
        };

        const args = std.json.parseFromValueLeaky(EvaluateParamsEx, arena, call_params.arguments.?, .{ .ignore_unknown_fields = true }) catch {
            return sendError(server, req.id.?, -32602, "Invalid arguments for evaluate");
        };

        if (args.url) |url| {
            performGoto(server, arena, url) catch {
                return sendError(server, req.id.?, -32603, "Internal error during navigation");
            };
        }

        var ls: js.Local.Scope = undefined;
        server.page.js.localScope(&ls);
        defer ls.deinit();

        const js_result = ls.local.compileAndRun(args.script, null) catch {
            const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Script evaluation failed." }};
            return sendResult(server, req.id.?, .{ .content = &content, .isError = true });
        };

        const str_result = js_result.toStringSliceWithAlloc(arena) catch "undefined";

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = str_result }};
        try sendResult(server, req.id.?, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "over")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id.?, -32602, "Missing arguments for over");
        }
        const args = std.json.parseFromValueLeaky(OverParams, arena, call_params.arguments.?, .{}) catch {
            return sendError(server, req.id.?, -32602, "Invalid arguments for over");
        };

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = args.result }};
        try sendResult(server, req.id.?, .{ .content = &content });
    } else {
        return sendError(server, req.id.?, -32601, "Tool not found");
    }
}

fn performGoto(server: *Server, arena: std.mem.Allocator, url: []const u8) !void {
    const url_z = try arena.dupeZ(u8, url);
    _ = server.page.navigate(url_z, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch {
        return error.NavigationFailed;
    };

    _ = server.session.wait(5000);
}

pub fn sendResult(server: *Server, id: std.json.Value, result: anytype) !void {
    const GenericResponse = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: @TypeOf(result),
    };
    try server.sendResponse(GenericResponse{
        .id = id,
        .result = result,
    });
}

pub fn sendError(server: *Server, id: std.json.Value, code: i64, message: []const u8) !void {
    try server.sendResponse(protocol.Response{
        .id = id,
        .@"error" = protocol.Error{
            .code = code,
            .message = message,
        },
    });
}
