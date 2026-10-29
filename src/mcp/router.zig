const std = @import("std");
const lp = @import("lightpanda");

const protocol = @import("protocol.zig");
const Queue = @import("Queue.zig").Queue;

const log = lp.log;

/// A queued stdio message. Owned by the queue; the worker frees the body and
/// the node after handling it.
const Message = struct {
    body: []u8,
    next: ?*Message = null,
};

const MessageQueue = Queue(Message);

/// Generic over the server type. The server must expose: `allocator`, a
/// `transport: Transport` field, and the per-method `handleInitialize`,
/// `handleToolList`, `handleToolCall` methods. `handleResourceList` /
/// `handleResourceRead` are optional — servers that don't expose
/// resources can omit them and the router returns `MethodNotFound`
/// automatically. When `input` is the file behind `reader` (stdio), the
/// server must also expose `idle`: reading moves to its own thread so a
/// long tool call can't block the stream (see `processRequestsConcurrent`),
/// and the calling thread — which owns the session's isolate, like the HTTP
/// transport's worker — drains the queue, handling one message at a time
/// and pumping the session in between.
pub fn processRequests(server: anytype, reader: *std.Io.Reader, input: ?std.Io.File) !void {
    if (input != null) return processRequestsConcurrent(server, reader);

    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const aa = arena.allocator();

        const buffered_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                log.debug(.mcp, "Message too long", .{});
                try server.sendError(.null, .InvalidRequest, "Message too long");
                _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
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

/// Stdio runs on two threads so a long tool call can't take the whole
/// server down with it: a `waitForScript` polling for its full timeout used
/// to block the read loop, so a caller that gave up on the request (the MCP
/// client sends `notifications/cancelled` on timeout) was never heard, and
/// every later call — even `ping` — queued behind the wait. The reader
/// thread parses lines and applies a cancellation directly (it must reach
/// the in-flight call, not queue behind it); everything else is queued for
/// the calling thread, which dispatches serially — V8 isolates are
/// thread-affine, so all browser work stays on this thread, like the HTTP
/// transport's worker.
fn processRequestsConcurrent(server: anytype, reader: *std.Io.Reader) !void {
    var queue: MessageQueue = .{};
    const reader_thread = try std.Thread.spawn(.{}, readLoop, .{ server, reader, &queue });
    defer reader_thread.join();

    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();

    // Drain fast while work is queued (`wait_ms == 0`), pump the session
    // once the queue runs dry, like the HTTP transport's worker.
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
            },
            .timeout => wait_ms = server.idle(),
            .closed => break,
        }
    }
}

/// Reads stdin until EOF, queueing messages for the worker. A cancellation
/// never enters the queue: `handleCancelledRequest` runs right here, or a
/// caller-abandoned request can't tell the server to stop.
fn readLoop(server: anytype, reader: *std.Io.Reader, queue: *MessageQueue) void {
    var peek_arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer peek_arena.deinit();

    while (true) {
        const buffered_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                log.debug(.mcp, "Message too long", .{});
                // Both threads write through the transport's mutex.
                server.sendError(.null, .InvalidRequest, "Message too long") catch {};
                _ = reader.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => {
                if (err != error.EndOfStream) log.err(.mcp, "stdin read error", .{ .err = err });
                break;
            },
        } orelse break;

        const trimmed = std.mem.trim(u8, buffered_line, " \r\t");
        if (trimmed.len == 0) continue;

        _ = peek_arena.reset(.retain_capacity);
        if (cancelledRequestId(peek_arena.allocator(), trimmed)) |request_id| {
            // The id borrows `peek_arena`; the server copies what it keeps.
            server.handleCancelledRequest(request_id);
            continue;
        }

        const msg = server.allocator.create(Message) catch |err| {
            log.err(.mcp, "Message queue OOM", .{ .err = err });
            break;
        };
        msg.* = .{ .body = server.allocator.dupe(u8, trimmed) catch |err| {
            server.allocator.destroy(msg);
            log.err(.mcp, "Message queue OOM", .{ .err = err });
            break;
        } };
        queue.push(msg);
    }
    queue.close();
}

/// The `requestId` if `line` is a `notifications/cancelled` notification,
/// else null (malformed ones fall through to the normal dispatch, which
/// ignores unknown id-less methods). The returned value borrows `arena`.
fn cancelledRequestId(arena: std.mem.Allocator, line: []const u8) ?std.json.Value {
    // Peek at the method first: parsing `params` as a full json.Value would
    // allocate for every large tool call streaming past the reader, and
    // only a cancellation needs it.
    const Peek = struct { method: ?[]const u8 = null };
    const peek = std.json.parseFromSliceLeaky(Peek, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    const method = peek.method orelse return null;
    if (!std.mem.eql(u8, method, "notifications/cancelled")) return null;

    const Params = struct { requestId: ?std.json.Value = null };
    const Body = struct { params: ?Params = null };
    const body = std.json.parseFromSliceLeaky(Body, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    const params = body.params orelse return null;
    return params.requestId orelse null;
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
