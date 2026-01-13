const std = @import("std");
const lp = @import("lightpanda");
const Http = @import("./http/Http.zig");

const Allocator = std.mem.Allocator;

// used in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // executable name

    var filter: ?[]const u8 = null;
    if (args.next()) |n| {
        filter = n;
    }

    var http_server = try TestHTTPServer.init();
    defer http_server.deinit();

    {
        var wg: std.Thread.WaitGroup = .{};
        wg.startMany(1);
        var thrd = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &http_server, &wg });
        thrd.detach();
        wg.wait();
    }
    lp.log.opts.level = .warn;

    var app = try lp.App.init(allocator, .{
        .run_mode = .serve,
        .tls_verify_host = false,
        .user_agent = "User-Agent: Lightpanda/1.0 internal-tester",
    });
    defer app.deinit();

    var test_arena = std.heap.ArenaAllocator.init(allocator);
    defer test_arena.deinit();

    var http = Http.init(test_arena, &app.config);
    defer http.deinit();

    var browser = try lp.Browser.init(app, &http);
    defer browser.deinit();

    const session = try browser.newSession();

    var dir = try std.fs.cwd().openDir("src/browser/tests/legacy/", .{ .iterate = true, .no_follow = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        _ = test_arena.reset(.retain_capacity);
        if (entry.kind != .file) {
            continue;
        }

        if (!std.mem.endsWith(u8, entry.basename, ".html")) {
            continue;
        }

        if (std.mem.endsWith(u8, entry.basename, ".skip.html")) {
            continue;
        }

        if (filter) |f| {
            if (std.mem.indexOf(u8, entry.path, f) == null) {
                continue;
            }
        }
        std.debug.print("\n===={s}====\n", .{entry.path});
        current_test = entry.path;
        run(test_arena.allocator(), entry.path, session) catch |err| {
            std.debug.print("Failure: {s} - {any}\n", .{ entry.path, err });
        };
    }
}

pub fn run(allocator: Allocator, file: []const u8, session: *lp.Session) !void {
    const url = try std.fmt.allocPrintSentinel(allocator, "http://localhost:9589/{s}", .{file}, 0);

    const page = try session.createPage();
    defer session.removePage();

    const js_context = page.js;
    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(js_context);
    defer try_catch.deinit();

    try page.navigate(url, .{});
    _ = session.wait(2000);

    js_context.eval("testing.assertOk()", "testing.assertOk()") catch |err| {
        const msg = try_catch.err(allocator) catch @errorName(err) orelse "unknown";

        std.debug.print("{s}: test failure\nError: {s}\n", .{ file, msg });
        return err;
    };
}

const TestHTTPServer = struct {
    shutdown: bool,
    dir: std.fs.Dir,
    listener: ?std.net.Server,

    pub fn init() !TestHTTPServer {
        return .{
            .dir = try std.fs.cwd().openDir("src/browser/tests/legacy/", .{}),
            .shutdown = true,
            .listener = null,
        };
    }

    pub fn deinit(self: *TestHTTPServer) void {
        self.shutdown = true;
        if (self.listener) |*listener| {
            listener.deinit();
        }
        self.dir.close();
    }

    pub fn run(self: *TestHTTPServer, wg: *std.Thread.WaitGroup) !void {
        const address = try std.net.Address.parseIp("127.0.0.1", 9589);

        self.listener = try address.listen(.{ .reuse_address = true });
        var listener = &self.listener.?;

        wg.finish();

        while (true) {
            const conn = listener.accept() catch |err| {
                if (self.shutdown) {
                    return;
                }
                return err;
            };
            const thrd = try std.Thread.spawn(.{}, handleConnection, .{ self, conn });
            thrd.detach();
        }
    }

    fn handleConnection(self: *TestHTTPServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        var req_buf: [2048]u8 = undefined;
        var conn_reader = conn.stream.reader(&req_buf);
        var conn_writer = conn.stream.writer(&req_buf);

        var http_server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

        while (true) {
            var req = http_server.receiveHead() catch |err| switch (err) {
                error.ReadFailed => continue,
                error.HttpConnectionClosing => continue,
                else => {
                    std.debug.print("Test HTTP Server error: {}\n", .{err});
                    return err;
                },
            };

            self.handler(&req) catch |err| {
                std.debug.print("test http error '{s}': {}\n", .{ req.head.target, err });
                try req.respond("server error", .{ .status = .internal_server_error });
                return;
            };
        }
    }

    fn handler(server: *TestHTTPServer, req: *std.http.Server.Request) !void {
        const path = req.head.target;

        if (std.mem.eql(u8, path, "/xhr")) {
            return req.respond("1234567890" ** 10, .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            });
        }

        if (std.mem.eql(u8, path, "/xhr/json")) {
            return req.respond("{\"over\":\"9000!!!\"}", .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        }

        // strip out leading '/' to make the path relative
        const file = try server.dir.openFile(path[1..], .{});
        defer file.close();

        const stat = try file.stat();
        var send_buffer: [4096]u8 = undefined;

        var res = try req.respondStreaming(&send_buffer, .{
            .content_length = stat.size,
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = getContentType(path) },
                },
            },
        });

        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(&read_buffer);
        _ = try res.writer.sendFileAll(&reader, .unlimited);
        try res.writer.flush();
        try res.end();
    }

    pub fn sendFile(req: *std.http.Server.Request, file_path: []const u8) !void {
        var file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return req.respond("server error", .{ .status = .not_found }),
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        var send_buffer: [4096]u8 = undefined;

        var res = try req.respondStreaming(&send_buffer, .{
            .content_length = stat.size,
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = getContentType(file_path) },
                },
            },
        });

        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(&read_buffer);
        _ = try res.writer.sendFileAll(&reader, .unlimited);
        try res.writer.flush();
        try res.end();
    }

    fn getContentType(file_path: []const u8) []const u8 {
        if (std.mem.endsWith(u8, file_path, ".js")) {
            return "application/json";
        }

        if (std.mem.endsWith(u8, file_path, ".html")) {
            return "text/html";
        }

        if (std.mem.endsWith(u8, file_path, ".htm")) {
            return "text/html";
        }

        if (std.mem.endsWith(u8, file_path, ".xml")) {
            // some wpt tests do this
            return "text/xml";
        }

        std.debug.print("TestHTTPServer asked to serve an unknown file type: {s}\n", .{file_path});
        return "text/html";
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("===panic running: {s}===\n", .{ct});
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);
