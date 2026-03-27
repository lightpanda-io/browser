const std = @import("std");
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const Server = @import("Server.zig");
const tools = @import("tools.zig");

pub fn processRequests(server: *Server, reader: *std.io.Reader) !void {
    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const aa = arena.allocator();

        const buffered_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                log.err(.mcp, "Message too long", .{});
                try server.sendError(.null, .InvalidRequest, "Message too long");
                continue;
            },
            else => return err,
        } orelse break;

        const trimmed = std.mem.trim(u8, buffered_line, " \r\t");
        if (trimmed.len > 0) {
            handleMessage(server, aa, trimmed) catch |err| {
                log.err(.mcp, "Failed to handle message", .{ .err = err, .msg = trimmed });
            };
        }
    }
}

const log = @import("../log.zig");

const Method = enum {
    initialize,
    ping,
    @"notifications/initialized",
    @"tools/list",
    @"tools/call",
    @"resources/list",
    @"resources/read",
};

const method_map = std.StaticStringMap(Method).initComptime(.{
    .{ "initialize", .initialize },
    .{ "ping", .ping },
    .{ "notifications/initialized", .@"notifications/initialized" },
    .{ "tools/list", .@"tools/list" },
    .{ "tools/call", .@"tools/call" },
    .{ "resources/list", .@"resources/list" },
    .{ "resources/read", .@"resources/read" },
});

pub fn handleMessage(server: *Server, arena: std.mem.Allocator, msg: []const u8) !void {
    const req = std.json.parseFromSliceLeaky(protocol.Request, arena, msg, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn(.mcp, "JSON Parse Error", .{ .err = err, .msg = msg });
        try server.sendError(.null, .ParseError, "Parse error");
        return;
    };

    const method = method_map.get(req.method) orelse {
        if (req.id != null) {
            try server.sendError(req.id.?, .MethodNotFound, "Method not found");
        }
        return;
    };

    switch (method) {
        .initialize => try handleInitialize(server, req),
        .ping => try handlePing(server, req),
        .@"notifications/initialized" => {},
        .@"tools/list" => try tools.handleList(server, arena, req),
        .@"tools/call" => try tools.handleCall(server, arena, req),
        .@"resources/list" => try resources.handleList(server, req),
        .@"resources/read" => try resources.handleRead(server, arena, req),
    }
}

fn handleInitialize(server: *Server, req: protocol.Request) !void {
    const id = req.id orelse return;
    const result = protocol.InitializeResult{
        .protocolVersion = "2025-11-25",
        .capabilities = .{
            .resources = .{},
            .tools = .{},
        },
        .serverInfo = .{
            .name = "lightpanda",
            .version = "0.1.0",
        },
    };

    try server.sendResult(id, result);
}

fn handlePing(server: *Server, req: protocol.Request) !void {
    const id = req.id orelse return;
    try server.sendResult(id, .{});
}

const testing = @import("../testing.zig");

test "MCP.router - handleMessage - synchronous unit tests" {
    defer testing.reset();
    const allocator = testing.allocator;
    const app = testing.test_app;

    var out_alloc: std.io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Server.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    const aa = testing.arena_allocator;

    // 1. Valid handshake
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    );
    try testing.expectJson(
        \\{ "jsonrpc": "2.0", "id": 1, "result": { "capabilities": { "tools": {} } } }
    , out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 2. Ping
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 2, .result = .{} }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 3. Tools list
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 3 }, out_alloc.writer.buffered());
    try testing.expect(std.mem.indexOf(u8, out_alloc.writer.buffered(), "\"name\":\"goto\"") != null);
    out_alloc.writer.end = 0;

    // 4. Method not found
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":4,"method":"unknown_method"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 4, .@"error" = .{ .code = -32601 } }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 5. Parse error
    {
        const filter: testing.LogFilter = .init(&.{.mcp});
        defer filter.deinit();

        try handleMessage(server, aa, "invalid json");
        try testing.expectJson("{\"jsonrpc\": \"2.0\", \"id\": null, \"error\": {\"code\": -32700}}", out_alloc.writer.buffered());
    }
}
