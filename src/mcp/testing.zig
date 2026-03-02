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
    test_error: ?anyerror = null,

    const Pipe = struct {
        read: std.fs.File,
        write: std.fs.File,

        fn init() !Pipe {
            const fds = try std.posix.pipe();
            return .{
                .read = .{ .handle = fds[0] },
                .write = .{ .handle = fds[1] },
            };
        }

        fn close(self: Pipe) void {
            self.read.close();
            self.write.close();
        }
    };

    pub fn init(allocator: std.mem.Allocator, app: *App) !*McpHarness {
        const self = try allocator.create(McpHarness);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.app = app;
        self.thread = null;
        self.test_error = null;

        const stdin_pipe = try Pipe.init();
        errdefer stdin_pipe.close();

        const stdout_pipe = try Pipe.init();
        errdefer {
            stdin_pipe.close();
            stdout_pipe.close();
        }

        self.server_in = stdin_pipe.read;
        self.client_out = stdin_pipe.write;
        self.client_in = stdout_pipe.read;
        self.server_out = stdout_pipe.write;

        self.server = try Server.init(allocator, app, self.server_out);
        errdefer self.server.deinit();

        return self;
    }

    pub fn deinit(self: *McpHarness) void {
        self.server.is_running.store(false, .release);

        // Wake up the server's poll loop by writing a newline
        self.client_out.writeAll("\n") catch {};

        // Closing the client's output will also send EOF to the server
        self.client_out.close();

        if (self.thread) |t| t.join();

        self.server.deinit();

        // Server handles are closed here if they weren't already
        self.server_in.close();
        self.server_out.close();
        self.client_in.close();
        // self.client_out is already closed above

        self.allocator.destroy(self);
    }

    pub fn runServer(self: *McpHarness) !void {
        try router.processRequests(self.server, self.server_in);
        if (self.test_error) |err| return err;
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

        const r = poller.reader(.stdout);

        const timeout_ns = 2 * std.time.ns_per_s;
        var timer = try std.time.Timer.start();

        while (timer.read() < timeout_ns) {
            const poll_result = try poller.pollTimeout(timeout_ns - timer.read());

            if (!poll_result) return error.EndOfStream;

            const buffered = r.buffered();
            if (std.mem.indexOfScalar(u8, buffered, '\n')) |newline_idx| {
                const line = buffered[0 .. newline_idx + 1];
                const result = try arena.dupe(u8, std.mem.trim(u8, line, " \r\n\t"));
                r.toss(line.len);
                return result;
            }
        }

        return error.Timeout;
    }
};
