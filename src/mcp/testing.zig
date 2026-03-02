const std = @import("std");
const lp = @import("lightpanda");
const App = @import("../App.zig");
const Server = @import("Server.zig");
const router = @import("router.zig");

pub const McpHarness = struct {
    allocator: std.mem.Allocator,
    app: *App,
    server: *Server,

    // Client view of the communication
    client_in: std.fs.File, // Client reads from this (server's stdout)
    client_out: std.fs.File, // Client writes to this (server's stdin)

    // Server view of the communication
    server_in: std.fs.File, // Server reads from this (client's stdout)
    server_out: std.fs.File, // Server writes to this (client's stdin)

    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, app: *App) !*McpHarness {
        const self = try allocator.create(McpHarness);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.app = app;
        self.thread = null;

        // Pipe for Server Stdin (Client writes, Server reads)
        const server_stdin_pipe = try std.posix.pipe();
        errdefer {
            std.posix.close(server_stdin_pipe[0]);
            std.posix.close(server_stdin_pipe[1]);
        }
        self.server_in = .{ .handle = server_stdin_pipe[0] };
        self.client_out = .{ .handle = server_stdin_pipe[1] };

        // Pipe for Server Stdout (Server writes, Client reads)
        const server_stdout_pipe = try std.posix.pipe();
        errdefer {
            std.posix.close(server_stdout_pipe[0]);
            std.posix.close(server_stdout_pipe[1]);
            self.server_in.close();
            self.client_out.close();
        }
        self.client_in = .{ .handle = server_stdout_pipe[0] };
        self.server_out = .{ .handle = server_stdout_pipe[1] };

        self.server = try Server.init(allocator, app, self.server_out);
        errdefer self.server.deinit();

        return self;
    }

    pub fn deinit(self: *McpHarness) void {
        self.server.is_running.store(false, .release);

        // Unblock poller if it's waiting for stdin
        self.client_out.writeAll("\n") catch {};

        if (self.thread) |t| t.join();

        self.server.deinit();

        self.server_in.close();
        self.server_out.close();
        self.client_in.close();
        self.client_out.close();

        self.allocator.destroy(self);
    }

    pub fn runServer(self: *McpHarness) !void {
        try router.processRequests(self.server, self.server_in);
    }

    pub fn sendRequest(self: *McpHarness, request_json: []const u8) !void {
        try self.client_out.writeAll(request_json);
        if (request_json.len > 0 and request_json[request_json.len - 1] != '\n') {
            try self.client_out.writeAll("\n");
        }
    }

    pub fn readResponse(self: *McpHarness, arena: std.mem.Allocator) ![]const u8 {
        const Streams = enum { stdout };
        var poller = std.io.poll(self.allocator, Streams, .{ .stdout = self.client_in });
        defer poller.deinit();

        var timeout_count: usize = 0;
        while (timeout_count < 20) : (timeout_count += 1) {
            const poll_result = try poller.pollTimeout(100 * std.time.ns_per_ms);
            const r = poller.reader(.stdout);
            const buffered = r.buffered();
            if (std.mem.indexOfScalar(u8, buffered, '\n')) |idx| {
                const line = try arena.dupe(u8, buffered[0..idx]);
                r.toss(idx + 1);
                return line;
            }
            if (!poll_result) return error.EndOfStream;
        }
        return error.Timeout;
    }
};
