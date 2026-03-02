const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;

const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const Server = @import("Server.zig");
const tools = @import("tools.zig");

pub fn processRequests(server: *Server, in_stream: std.fs.File) !void {
    server.is_running.store(true, .release);

    const Streams = enum { stdin };
    var poller = std.io.poll(server.allocator, Streams, .{ .stdin = in_stream });
    defer poller.deinit();

    const reader = poller.reader(.stdin);

    var arena_instance = std.heap.ArenaAllocator.init(server.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    while (server.is_running.load(.acquire)) {
        // Run ready browser tasks and get time to next one
        const ms_to_next_task = (try server.browser.runMacrotasks()) orelse 10_000;

        // Keep the loop responsive to network events and stdin.
        const ms_to_wait: u64 = @min(50, ms_to_next_task);

        // Wait for stdin activity for up to ms_to_wait.
        const poll_result = try poller.pollTimeout(ms_to_wait * @as(u64, std.time.ns_per_ms));

        // Process any pending network I/O
        _ = try server.http_client.tick(0);

        // Process all complete lines available in the buffer
        while (true) {
            const buffered = reader.buffered();
            if (std.mem.indexOfScalar(u8, buffered, '\n')) |idx| {
                const line = buffered[0..idx];
                if (line.len > 0) {
                    handleMessage(server, arena, line) catch |err| {
                        log.warn(.mcp, "Error processing message", .{ .err = err });
                    };
                    _ = arena_instance.reset(.{ .retain_with_limit = 32 * 1024 });
                }
                reader.toss(idx + 1);
            } else {
                break;
            }
        }

        // pollTimeout returns false when all streams are closed (EOF on stdin)
        if (!poll_result) {
            const buffered = reader.buffered();
            if (buffered.len > 0) {
                handleMessage(server, arena, buffered) catch {};
            }
            break;
        }
    }
}

fn handleMessage(server: *Server, arena: std.mem.Allocator, msg: []const u8) !void {
    const parsed = std.json.parseFromSliceLeaky(protocol.Request, arena, msg, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn(.mcp, "JSON Parse Error", .{ .err = err, .msg = msg });
        try server.sendError(.null, .ParseError, "Parse error");
        return;
    };

    if (parsed.id == null) {
        // It's a notification
        if (std.mem.eql(u8, parsed.method, "notifications/initialized")) {
            log.info(.mcp, "Client Initialized", .{});
        }
        return;
    }

    if (std.mem.eql(u8, parsed.method, "initialize")) {
        try handleInitialize(server, parsed);
    } else if (std.mem.eql(u8, parsed.method, "resources/list")) {
        try resources.handleList(server, parsed);
    } else if (std.mem.eql(u8, parsed.method, "resources/read")) {
        try resources.handleRead(server, arena, parsed);
    } else if (std.mem.eql(u8, parsed.method, "tools/list")) {
        try tools.handleList(server, arena, parsed);
    } else if (std.mem.eql(u8, parsed.method, "tools/call")) {
        try tools.handleCall(server, arena, parsed);
    } else {
        try server.sendError(parsed.id.?, .MethodNotFound, "Method not found");
    }
}

fn handleInitialize(server: *Server, req: protocol.Request) !void {
    const result = protocol.InitializeResult{
        .protocolVersion = "2025-11-25",
        .capabilities = .{
            .logging = .{},
            .prompts = .{ .listChanged = false },
            .resources = .{ .subscribe = false, .listChanged = false },
            .tools = .{ .listChanged = false },
        },
        .serverInfo = .{
            .name = "lightpanda-mcp",
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

    harness.thread = try std.Thread.spawn(.{}, testParseError, .{harness});
    try harness.runServer();
}

fn testParseError(harness: *McpHarness) void {
    defer harness.server.is_running.store(false, .release);

    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();

    harness.sendRequest("invalid json") catch return;

    const response = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response, "\"id\":null") != null) catch return;
    testing.expect(std.mem.indexOf(u8, response, "\"code\":-32700") != null) catch return;
}
