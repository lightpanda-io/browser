const std = @import("std");
const McpServer = @import("Server.zig").McpServer;
const protocol = @import("protocol.zig");
const lp = @import("lightpanda");
const log = lp.log;
const js = lp.js;

const Node = @import("../browser/webapi/Node.zig");
const Element = @import("../browser/webapi/Element.zig");
const Selector = @import("../browser/webapi/selector/Selector.zig");
const String = @import("../string.zig").String;

pub fn handleList(server: *McpServer, req: protocol.Request) !void {
    const tools = [_]protocol.Tool{
        .{
            .name = "goto",
            .description = "Navigate to a specified URL and load the page in memory so it can be reused later for info extraction.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, server.allocator,
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
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, server.allocator,
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
            .description = "Get the page content in markdown format.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, server.allocator, "{\"type\":\"object\",\"properties\":{}}", .{}) catch unreachable,
        },
        .{
            .name = "links",
            .description = "Extract all links in the opened page",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, server.allocator, "{\"type\":\"object\",\"properties\":{}}", .{}) catch unreachable,
        },
        .{
            .name = "evaluate",
            .description = "Evaluate JavaScript in the current page context",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, server.allocator,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "script": { "type": "string" }
                \\  },
                \\  "required": ["script"]
                \\}
            , .{}) catch unreachable,
        },
        .{
            .name = "over",
            .description = "Used to indicate that the task is over and give the final answer if there is any. This is the last tool to be called in a task.",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, server.allocator,
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

    try sendResult(server, req.id, result);
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

pub fn handleCall(server: *McpServer, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null) {
        return sendError(server, req.id, -32602, "Missing params");
    }

    const CallParams = struct {
        name: []const u8,
        arguments: ?std.json.Value = null,
    };

    const call_params = std.json.parseFromValueLeaky(CallParams, arena, req.params.?, .{}) catch {
        return sendError(server, req.id, -32602, "Invalid params");
    };

    if (std.mem.eql(u8, call_params.name, "goto") or std.mem.eql(u8, call_params.name, "navigate")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id, -32602, "Missing arguments for goto");
        }
        const args = std.json.parseFromValueLeaky(GotoParams, arena, call_params.arguments.?, .{}) catch {
            return sendError(server, req.id, -32602, "Invalid arguments for goto");
        };

        try performGoto(server, arena, args.url);

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Navigated successfully." }};
        try sendResult(server, req.id, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "search")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id, -32602, "Missing arguments for search");
        }
        const args = std.json.parseFromValueLeaky(SearchParams, arena, call_params.arguments.?, .{}) catch {
            return sendError(server, req.id, -32602, "Invalid arguments for search");
        };

        const component: std.Uri.Component = .{ .raw = args.text };
        var url_aw = std.Io.Writer.Allocating.init(arena);
        try component.formatQuery(&url_aw.writer);
        const url = try std.fmt.allocPrint(arena, "https://duckduckgo.com/?q={s}", .{url_aw.written()});

        try performGoto(server, arena, url);

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Search performed successfully." }};
        try sendResult(server, req.id, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "markdown")) {
        var aw = std.Io.Writer.Allocating.init(arena);
        try lp.markdown.dump(server.page.document.asNode(), .{}, &aw.writer, server.page);

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = aw.written() }};
        try sendResult(server, req.id, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "links")) {
        const list = try Selector.querySelectorAll(server.page.document.asNode(), "a[href]", server.page);

        var aw = std.Io.Writer.Allocating.init(arena);
        var first = true;
        for (list._nodes) |node| {
            if (node.is(Element)) |el| {
                if (el.getAttributeSafe(String.wrap("href"))) |href| {
                    if (!first) try aw.writer.writeByte('\n');
                    try aw.writer.writeAll(href);
                    first = false;
                }
            }
        }

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = aw.written() }};
        try sendResult(server, req.id, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "evaluate")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id, -32602, "Missing arguments for evaluate");
        }
        const args = std.json.parseFromValueLeaky(EvaluateParams, arena, call_params.arguments.?, .{}) catch {
            return sendError(server, req.id, -32602, "Invalid arguments for evaluate");
        };

        var ls: js.Local.Scope = undefined;
        server.page.js.localScope(&ls);
        defer ls.deinit();

        const js_result = ls.local.compileAndRun(args.script, null) catch {
            const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Script evaluation failed." }};
            return sendResult(server, req.id, .{ .content = &content, .isError = true });
        };

        const str_result = js_result.toStringSliceWithAlloc(arena) catch "undefined";

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = str_result }};
        try sendResult(server, req.id, .{ .content = &content });
    } else if (std.mem.eql(u8, call_params.name, "over")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id, -32602, "Missing arguments for over");
        }
        const args = std.json.parseFromValueLeaky(OverParams, arena, call_params.arguments.?, .{}) catch {
            return sendError(server, req.id, -32602, "Invalid arguments for over");
        };

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = args.result }};
        try sendResult(server, req.id, .{ .content = &content });
    } else {
        return sendError(server, req.id, -32601, "Tool not found");
    }
}

fn performGoto(server: *McpServer, arena: std.mem.Allocator, url: []const u8) !void {
    const url_z = try arena.dupeZ(u8, url);
    _ = server.page.navigate(url_z, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch {
        return error.NavigationFailed;
    };

    _ = server.session.wait(5000);
}

pub fn sendResult(server: *McpServer, id: std.json.Value, result: anytype) !void {
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

pub fn sendError(server: *McpServer, id: std.json.Value, code: i64, message: []const u8) !void {
    try server.sendResponse(protocol.Response{
        .id = id,
        .@"error" = protocol.Error{
            .code = code,
            .message = message,
        },
    });
}
