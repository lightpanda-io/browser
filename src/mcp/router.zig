const std = @import("std");
const lp = @import("lightpanda");
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const Server = @import("Server.zig");
const tools = @import("tools.zig");

pub fn processRequests(server: *Server, in_stream: std.fs.File) !void {
    server.is_running.store(true, .release);

    const Streams = enum { stdin };
    var poller = std.io.poll(server.allocator, Streams, .{ .stdin = in_stream });
    defer poller.deinit();

    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(server.allocator);

    while (server.is_running.load(.acquire)) {
        const poll_result = try poller.pollTimeout(100 * std.time.ns_per_ms);

        if (poll_result) {
            const data = try poller.toOwnedSlice(.stdin);
            if (data.len == 0) {
                server.is_running.store(false, .release);
                break;
            }
            try buffer.appendSlice(server.allocator, data);
            server.allocator.free(data);
        }

        while (std.mem.indexOfScalar(u8, buffer.items, '\n')) |newline_idx| {
            const line = try server.allocator.dupe(u8, buffer.items[0..newline_idx]);
            defer server.allocator.free(line);

            const remaining = buffer.items.len - (newline_idx + 1);
            std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[newline_idx + 1 ..]);
            buffer.items.len = remaining;

            // Ignore empty lines (e.g. from deinit unblock)
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;

            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();

            handleMessage(server, arena.allocator(), trimmed) catch |err| {
                log.err(.mcp, "Failed to handle message", .{ .err = err, .msg = trimmed });
            };
        }
    }
}

const log = @import("../log.zig");

fn handleMessage(server: *Server, arena: std.mem.Allocator, msg: []const u8) !void {
    const req = std.json.parseFromSlice(protocol.Request, arena, msg, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn(.mcp, "JSON Parse Error", .{ .err = err, .msg = msg });
        try server.sendError(.null, .ParseError, "Parse error");
        return;
    };

    if (std.mem.eql(u8, req.value.method, "initialize")) {
        return handleInitialize(server, req.value);
    }

    if (std.mem.eql(u8, req.value.method, "notifications/initialized")) {
        // nothing to do
        return;
    }

    if (std.mem.eql(u8, req.value.method, "tools/list")) {
        return tools.handleList(server, arena, req.value);
    }

    if (std.mem.eql(u8, req.value.method, "tools/call")) {
        return tools.handleCall(server, arena, req.value);
    }

    if (std.mem.eql(u8, req.value.method, "resources/list")) {
        return resources.handleList(server, req.value);
    }

    if (std.mem.eql(u8, req.value.method, "resources/read")) {
        return resources.handleRead(server, arena, req.value);
    }

    if (req.value.id != null) {
        return server.sendError(req.value.id.?, .MethodNotFound, "Method not found");
    }
}

fn handleInitialize(server: *Server, req: protocol.Request) !void {
    const result = protocol.InitializeResult{
        .protocolVersion = "2025-11-25",
        .capabilities = .{},
        .serverInfo = .{
            .name = "lightpanda",
            .version = "0.1.0",
        },
    };

    try server.sendResult(req.id.?, result);
}

const testing = @import("../testing.zig");
const McpHarness = @import("testing.zig").McpHarness;

test "handleMessage - ParseError" {
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    harness.thread = try std.Thread.spawn(.{}, wrapTest, .{ testParseErrorInternal, harness });
    try harness.runServer();
}

fn wrapTest(comptime func: fn (*McpHarness) anyerror!void, harness: *McpHarness) void {
    const res = func(harness);
    if (res) |_| {
        harness.test_error = null;
    } else |err| {
        harness.test_error = err;
    }
    harness.server.is_running.store(false, .release);
    // Ensure we trigger a poll wake up if needed
    _ = harness.client_out.writeAll("\n") catch {};
}

fn testParseErrorInternal(harness: *McpHarness) !void {
    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();

    try harness.sendRequest("invalid json");

    const response = try harness.readResponse(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, response, "\"id\":null") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32700") != null);
}
