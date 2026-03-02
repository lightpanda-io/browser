const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;

const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const Server = @import("Server.zig");
const tools = @import("tools.zig");

pub fn processRequests(server: *Server) !void {
    server.is_running.store(true, .release);

    const Streams = enum { stdin };
    var poller = std.io.poll(server.allocator, Streams, .{ .stdin = std.fs.File.stdin() });
    defer poller.deinit();

    const reader = poller.reader(.stdin);

    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();

    while (server.is_running.load(.acquire)) {
        const ms_to_next_task = (try server.browser.runMacrotasks()) orelse 10_000;

        // Poll until the next macrotask is scheduled. This will block if no data is available.
        const poll_ok = try poller.pollTimeout(ms_to_next_task * std.time.ns_per_ms);

        while (true) {
            const buffered = reader.buffered();
            if (std.mem.indexOfScalar(u8, buffered, '\n')) |idx| {
                const line = buffered[0..idx];
                if (line.len > 0) {
                    handleMessage(server, arena.allocator(), line) catch |err| {
                        log.warn(.mcp, "Error processing message", .{ .err = err });
                    };
                    _ = arena.reset(.{ .retain_with_limit = 32 * 1024 });
                }
                reader.toss(idx + 1);
            } else {
                break;
            }
        }

        if (!poll_ok) {
            // Check if we have any data left in the buffer that didn't end with a newline
            const buffered = reader.buffered();
            if (buffered.len > 0) {
                handleMessage(server, arena.allocator(), buffered) catch |err| {
                    log.warn(.mcp, "Error processing last message", .{ .err = err });
                };
            }
            break;
        }

        server.browser.runMessageLoop();
    }
}

fn handleMessage(server: *Server, arena: std.mem.Allocator, msg: []const u8) !void {
    const parsed = std.json.parseFromSliceLeaky(protocol.Request, arena, msg, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn(.mcp, "JSON Parse Error", .{ .err = err, .msg = msg });
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

    try server.sendResult(req.id.?, result);
}
