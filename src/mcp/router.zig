const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;

const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const Server = @import("Server.zig");
const tools = @import("tools.zig");

pub fn processRequests(server: *Server) !void {
    var stdin_file = std.fs.File.stdin();
    var stdin_buf: [8192]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);

    server.is_running.store(true, .seq_cst);

    while (server.is_running.load(.seq_cst)) {
        const msg = stdin.interface.adaptToOldInterface().readUntilDelimiterAlloc(server.allocator, '\n', 1024 * 1024 * 10) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer server.allocator.free(msg);

        if (msg.len == 0) continue;

        // Critical: Per-request Arena
        var arena = std.heap.ArenaAllocator.init(server.allocator);
        defer arena.deinit();

        handleMessage(server, arena.allocator(), msg) catch |err| {
            log.err(.app, "MCP Error processing message", .{ .err = err });
            // We should ideally send a parse error response back, but it's hard to extract the ID if parsing failed entirely.
        };
    }
}

fn handleMessage(server: *Server, arena: std.mem.Allocator, msg: []const u8) !void {
    const parsed = std.json.parseFromSliceLeaky(protocol.Request, arena, msg, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err(.app, "MCP JSON Parse Error", .{ .err = err, .msg = msg });
        return;
    };

    if (parsed.id == null) {
        // It's a notification
        if (std.mem.eql(u8, parsed.method, "notifications/initialized")) {
            log.info(.app, "MCP Client Initialized", .{});
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
        try server.sendResponse(protocol.Response{
            .id = parsed.id.?,
            .@"error" = protocol.Error{
                .code = -32601,
                .message = "Method not found",
            },
        });
    }
}

fn sendResponseGeneric(server: *Server, id: std.json.Value, result: anytype) !void {
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

    try sendResponseGeneric(server, req.id.?, result);
}
