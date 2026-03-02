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

    const r = poller.reader(.stdin);

    while (server.is_running.load(.acquire)) {
        const poll_result = try poller.pollTimeout(100 * std.time.ns_per_ms);

        if (!poll_result) {
            // EOF or all streams closed
            server.is_running.store(false, .release);
            break;
        }

        while (true) {
            const buffered = r.buffered();
            const newline_idx = std.mem.indexOfScalar(u8, buffered, '\n') orelse break;
            const line = buffered[0 .. newline_idx + 1];

            const trimmed = std.mem.trim(u8, line, " \r\n\t");
            if (trimmed.len > 0) {
                var arena = std.heap.ArenaAllocator.init(server.allocator);
                defer arena.deinit();

                handleMessage(server, arena.allocator(), trimmed) catch |err| {
                    log.err(.mcp, "Failed to handle message", .{ .err = err, .msg = trimmed });
                };
            }

            r.toss(line.len);
        }
    }
}

const log = @import("../log.zig");

const Method = enum {
    initialize,
    @"notifications/initialized",
    @"tools/list",
    @"tools/call",
    @"resources/list",
    @"resources/read",
};

const method_map = std.StaticStringMap(Method).initComptime(.{
    .{ "initialize", .initialize },
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
        .@"notifications/initialized" => {},
        .@"tools/list" => try tools.handleList(server, arena, req),
        .@"tools/call" => try tools.handleCall(server, arena, req),
        .@"resources/list" => try resources.handleList(server, req),
        .@"resources/read" => try resources.handleRead(server, arena, req),
    }
}

fn handleInitialize(server: *Server, req: protocol.Request) !void {
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

    try server.sendResult(req.id.?, result);
}

const testing = @import("../testing.zig");
const McpHarness = @import("testing.zig").McpHarness;

test "handleMessage - synchronous unit tests" {
    // We need a server, but we want it to write to our fbs
    // Server.init currently takes std.fs.File, we might need to refactor it
    // to take a generic writer if we want to be truly "cranky" and avoid OS files.
    // For now, let's use the harness as it's already set up, but call handleMessage directly.
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // 1. Valid request
    try handleMessage(harness.server, aa,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    const resp1 = try harness.readResponse(aa);
    try testing.expect(std.mem.indexOf(u8, resp1, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, resp1, "\"name\":\"lightpanda\"") != null);

    // 2. Method not found
    try handleMessage(harness.server, aa,
        \\{"jsonrpc":"2.0","id":2,"method":"unknown_method"}
    );
    const resp2 = try harness.readResponse(aa);
    try testing.expect(std.mem.indexOf(u8, resp2, "\"id\":2") != null);
    try testing.expect(std.mem.indexOf(u8, resp2, "\"code\":-32601") != null);

    // 3. Parse error
    {
        const old_filter = log.opts.filter_scopes;
        log.opts.filter_scopes = &.{.mcp};
        defer log.opts.filter_scopes = old_filter;

        try handleMessage(harness.server, aa, "invalid json");
        const resp3 = try harness.readResponse(aa);
        try testing.expect(std.mem.indexOf(u8, resp3, "\"id\":null") != null);
        try testing.expect(std.mem.indexOf(u8, resp3, "\"code\":-32700") != null);
    }
}
