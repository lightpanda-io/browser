const std = @import("std");
const lp = @import("lightpanda");
const McpServer = @import("Server.zig").McpServer;
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const tools = @import("tools.zig");
const log = lp.log;

pub fn processRequests(server: *McpServer) void {
    while (server.is_running.load(.seq_cst)) {
        if (server.getNextMessage()) |msg| {
            defer server.allocator.free(msg);

            // Critical: Per-request Arena
            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();

            handleMessage(server, arena.allocator(), msg) catch |err| {
                log.err(.app, "MCP Error processing message", .{ .err = err });
                // We should ideally send a parse error response back, but it's hard to extract the ID if parsing failed entirely.
            };
        }
    }
}

fn handleMessage(server: *McpServer, arena: std.mem.Allocator, msg: []const u8) !void {
    const parsed = std.json.parseFromSliceLeaky(protocol.Request, arena, msg, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err(.app, "MCP JSON Parse Error", .{ .err = err, .msg = msg });
        return;
    };

    if (std.mem.eql(u8, parsed.method, "initialize")) {
        try handleInitialize(server, parsed);
    } else if (std.mem.eql(u8, parsed.method, "resources/list")) {
        try resources.handleList(server, parsed);
    } else if (std.mem.eql(u8, parsed.method, "resources/read")) {
        try resources.handleRead(server, arena, parsed);
    } else if (std.mem.eql(u8, parsed.method, "tools/list")) {
        try tools.handleList(server, parsed);
    } else if (std.mem.eql(u8, parsed.method, "tools/call")) {
        try tools.handleCall(server, arena, parsed);
    } else {
        try server.sendResponse(protocol.Response{
            .id = parsed.id,
            .@"error" = protocol.Error{
                .code = -32601,
                .message = "Method not found",
            },
        });
    }
}

fn sendResponseGeneric(server: *McpServer, id: std.json.Value, result: anytype) !void {
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

fn handleInitialize(server: *McpServer, req: protocol.Request) !void {
    const result = protocol.InitializeResult{
        .protocolVersion = "2024-11-05",
        .capabilities = .{
            .logging = .{},
            .resources = .{ .subscribe = false, .listChanged = false },
            .tools = .{ .listChanged = false },
        },
        .serverInfo = .{
            .name = "lightpanda-mcp",
            .version = "0.1.0",
        },
    };

    try sendResponseGeneric(server, req.id, result);
}
