const std = @import("std");
const lp = @import("lightpanda");

const protocol = @import("protocol.zig");
const Queue = @import("Queue.zig").Queue;

const log = lp.log;

/// A queued stdio line; the dispatcher frees the body and the node.
const Message = struct {
    body: []u8,
    next: ?*Message = null,
};

const MessageQueue = Queue(Message);

/// Generic over the server type. The server must expose: `allocator`, a
/// `transport: Transport` field, `idle`, `handleCancelledRequest`, and the
/// per-method `handleInitialize`, `handleToolList`, `handleToolCall` methods.
/// `handleResourceList` / `handleResourceRead` are optional — servers that
/// don't expose resources can omit them and the router returns
/// `MethodNotFound` automatically.
///
/// A reader thread takes lines off `reader` so a cancellation can reach the
/// call in flight; this thread owns the session's isolate and dispatches the
/// rest one at a time, pumping the session in between.
pub fn processRequests(server: anytype, reader: *std.Io.Reader) !void {
    var queue: MessageQueue = .{};
    const reader_thread = try std.Thread.spawn(.{}, readLoop, .{ server, reader, &queue });
    defer reader_thread.join();

    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();

    var wait_ms: u64 = 0;
    while (true) {
        switch (queue.pop(wait_ms)) {
            .item => |msg| {
                defer {
                    server.allocator.free(msg.body);
                    server.allocator.destroy(msg);
                }
                _ = arena.reset(.retain_capacity);
                handleMessage(server, arena.allocator(), msg.body) catch |err| {
                    log.err(.mcp, "Failed to handle message", .{ .err = err, .msg = msg.body });
                };
                wait_ms = 0;
            },
            .timeout => wait_ms = server.idle(),
            .closed => break,
        }
    }
}

fn readLoop(server: anytype, reader: *std.Io.Reader, queue: *MessageQueue) void {
    defer queue.close();

    var peek_arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer peek_arena.deinit();

    while (true) {
        const buffered_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                log.debug(.mcp, "Message too long", .{});
                server.sendError(.null, .InvalidRequest, "Message too long") catch {};
                _ = reader.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            else => {
                if (err != error.EndOfStream) log.err(.mcp, "stdin read error", .{ .err = err });
                return;
            },
        } orelse return;

        const trimmed = std.mem.trim(u8, buffered_line, " \r\t");
        if (trimmed.len == 0) continue;

        // Applied here, not queued: it must reach the call in flight.
        _ = peek_arena.reset(.retain_capacity);
        if (cancelledRequestId(peek_arena.allocator(), trimmed)) |request_id| {
            server.handleCancelledRequest(request_id);
            continue;
        }

        enqueue(server.allocator, queue, trimmed) catch |err| {
            log.err(.mcp, "Message queue OOM", .{ .err = err });
            return;
        };
    }
}

fn enqueue(allocator: std.mem.Allocator, queue: *MessageQueue, line: []const u8) !void {
    const msg = try allocator.create(Message);
    errdefer allocator.destroy(msg);
    msg.* = .{ .body = try allocator.dupe(u8, line) };
    queue.push(msg);
}

/// The `requestId` if `line` is a `notifications/cancelled`, borrowing
/// `arena`.
fn cancelledRequestId(arena: std.mem.Allocator, line: []const u8) ?std.json.Value {
    // Skip the JSON scan for the (large) tool calls streaming past.
    if (std.mem.find(u8, line, "notifications/cancelled") == null) return null;
    const Peek = struct {
        method: ?[]const u8 = null,
        params: ?struct { requestId: ?std.json.Value = null } = null,
    };
    const peek = std.json.parseFromSliceLeaky(Peek, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    const method = peek.method orelse return null;
    if (!std.mem.eql(u8, method, "notifications/cancelled")) return null;
    const params = peek.params orelse return null;
    return params.requestId;
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
        log.debug(.mcp, "JSON Parse Error", .{ .err = err, .msg = msg });
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
    try server.sendResult(id, struct {}{});
}

const Server = @import("Server.zig");
const testing = @import("../testing.zig");

test "MCP.router - handleMessage - synchronous unit tests" {
    const allocator = testing.allocator;
    const app = testing.test_app;

    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
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
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 2, .result = struct {}{} }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 3. Tools list
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 3 }, out_alloc.writer.buffered());
    try testing.expect(std.mem.find(u8, out_alloc.writer.buffered(), "\"name\":\"goto\"") != null);
    out_alloc.writer.end = 0;

    // 4. Method not found
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":4,"method":"unknown_method"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 4, .@"error" = .{ .code = -32601 } }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 5. Parse error
    {
        try handleMessage(server, aa, "invalid json");
        try testing.expectJson("{\"jsonrpc\": \"2.0\", \"id\": null, \"error\": {\"code\": -32700}}", out_alloc.writer.buffered());
    }
}
