const std = @import("std");
const McpServer = @import("Server.zig").McpServer;
const protocol = @import("protocol.zig");
const lp = @import("lightpanda");
const log = lp.log;
const js = lp.js;

pub fn handleList(server: *McpServer, req: protocol.Request) !void {
    const tools = [_]protocol.Tool{
        .{
            .name = "navigate",
            .description = "Navigate the browser to a specific URL",
            .inputSchema = std.json.parseFromSliceLeaky(std.json.Value, server.allocator,
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "url": { "type": "string" }
                \\  },
                \\  "required": ["url"]
                \\}
            , .{}) catch unreachable,
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
    };

    const result = struct {
        tools: []const protocol.Tool,
    }{
        .tools = &tools,
    };

    try sendResult(server, req.id, result);
}

const NavigateParams = struct {
    url: []const u8,
};

const EvaluateParams = struct {
    script: []const u8,
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

    if (std.mem.eql(u8, call_params.name, "navigate")) {
        if (call_params.arguments == null) {
            return sendError(server, req.id, -32602, "Missing arguments for navigate");
        }
        const args = std.json.parseFromValueLeaky(NavigateParams, arena, call_params.arguments.?, .{}) catch {
            return sendError(server, req.id, -32602, "Invalid arguments for navigate");
        };

        const url_z = try arena.dupeZ(u8, args.url);
        _ = server.page.navigate(url_z, .{
            .reason = .address_bar,
            .kind = .{ .push = null },
        }) catch {
            return sendError(server, req.id, -32603, "Failed to navigate");
        };

        // Wait for page load (simple wait for now)
        _ = server.session.wait(5000);

        const content = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "Navigated successfully." }};
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
    } else {
        return sendError(server, req.id, -32601, "Tool not found");
    }
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
