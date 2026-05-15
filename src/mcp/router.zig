const std = @import("std");
const lp = @import("lightpanda");

const protocol = @import("protocol.zig");

const log = lp.log;

/// Generic over the server type. The server must expose: `allocator`, a
/// `transport: Transport` field, and the per-method `handleInitialize`,
/// `handleToolList`, `handleToolCall` methods. `handleResourceList` /
/// `handleResourceRead` are optional — servers that don't expose
/// resources can omit them and the router returns `MethodNotFound`
/// automatically.
pub fn processRequests(server: anytype, reader: *std.io.Reader) !void {
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

pub fn handleMessage(server: anytype, arena: std.mem.Allocator, msg: []const u8) !void {
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
        .initialize => try server.handleInitialize(req),
        .ping => try handlePing(server, req),
        .@"notifications/initialized" => {},
        .@"tools/list" => try server.handleToolList(arena, req),
        .@"tools/call" => try server.handleToolCall(arena, req),
        .@"resources/list" => try handleOptional(server, req, "handleResourceList", .{req}),
        .@"resources/read" => try handleOptional(server, req, "handleResourceRead", .{ arena, req }),
    }
}

fn handleOptional(server: anytype, req: protocol.Request, comptime method: []const u8, args: anytype) !void {
    if (@hasDecl(@TypeOf(server.*), method)) {
        try @call(.auto, @field(@TypeOf(server.*), method), .{server} ++ args);
    } else if (req.id) |id| {
        try server.sendError(id, .MethodNotFound, "Method not supported");
    }
}

fn handlePing(server: anytype, req: protocol.Request) !void {
    const id = req.id orelse return;
    try server.sendResult(id, .{});
}

const Server = @import("Server.zig");
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
        \\{ "jsonrpc": "2.0", "id": 1, "result": { "protocolVersion": "2024-11-05", "capabilities": { "tools": {} } } }
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
