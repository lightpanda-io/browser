const std = @import("std");

const TestHTTPServer = @This();

shutdown: bool,
listener: ?std.net.Server,
handler: Handler,

const Handler = *const fn (req: *std.http.Server.Request) anyerror!void;

pub fn init(handler: Handler) TestHTTPServer {
    return .{
        .shutdown = true,
        .listener = null,
        .handler = handler,
    };
}

pub fn deinit(self: *TestHTTPServer) void {
    self.shutdown = true;
    if (self.listener) |*listener| {
        listener.deinit();
    }
}

pub fn run(self: *TestHTTPServer, wg: *std.Thread.WaitGroup) !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 9582);

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
