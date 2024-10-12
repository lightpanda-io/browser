// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const posix = std.posix;

const jsruntime = @import("jsruntime");

const Browser = @import("browser/browser.zig").Browser;
const server = @import("server.zig");

const parser = @import("netsurf");
const apiweb = @import("apiweb.zig");

pub const Types = jsruntime.reflect(apiweb.Interfaces);
pub const UserContext = apiweb.UserContext;

// Default options
const Host = "127.0.0.1";
const Port = 3245;
const Timeout = 3; // in seconds

const usage =
    \\usage: {s} [options]
    \\  start Lightpanda browser in CDP server mode
    \\
    \\  -h, --help      Print this help message and exit.
    \\  --host          Host of the server (default "127.0.0.1")
    \\  --port          Port of the server (default "3245")
    \\  --timeout       Timeout for incoming connections in seconds (default "3")
    \\
;

// Inspired by std.net.StreamServer in Zig < 0.12
pub const StreamServer = struct {
    /// Copied from `Options` on `init`.
    kernel_backlog: u31,
    reuse_address: bool,
    reuse_port: bool,
    nonblocking: bool,

    /// `undefined` until `listen` returns successfully.
    listen_address: std.net.Address,

    sockfd: ?posix.socket_t,

    pub const Options = struct {
        /// How many connections the kernel will accept on the application's behalf.
        /// If more than this many connections pool in the kernel, clients will start
        /// seeing "Connection refused".
        kernel_backlog: u31 = 128,

        /// Enable SO.REUSEADDR on the socket.
        reuse_address: bool = false,

        /// Enable SO.REUSEPORT on the socket.
        reuse_port: bool = false,

        /// Non-blocking mode.
        nonblocking: bool = false,
    };

    /// After this call succeeds, resources have been acquired and must
    /// be released with `deinit`.
    pub fn init(options: Options) StreamServer {
        return StreamServer{
            .sockfd = null,
            .kernel_backlog = options.kernel_backlog,
            .reuse_address = options.reuse_address,
            .reuse_port = options.reuse_port,
            .nonblocking = options.nonblocking,
            .listen_address = undefined,
        };
    }

    /// Release all resources. The `StreamServer` memory becomes `undefined`.
    pub fn deinit(self: *StreamServer) void {
        self.close();
        self.* = undefined;
    }

    pub fn listen(self: *StreamServer, address: std.net.Address) !void {
        const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
        var use_sock_flags: u32 = sock_flags;
        if (self.nonblocking) use_sock_flags |= posix.SOCK.NONBLOCK;
        const proto = if (address.any.family == posix.AF.UNIX) @as(u32, 0) else posix.IPPROTO.TCP;

        const sockfd = try posix.socket(address.any.family, use_sock_flags, proto);
        self.sockfd = sockfd;
        errdefer {
            posix.close(sockfd);
            self.sockfd = null;
        }

        if (self.reuse_address) {
            try posix.setsockopt(
                sockfd,
                posix.SOL.SOCKET,
                posix.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }
        if (@hasDecl(posix.SO, "REUSEPORT") and self.reuse_port) {
            try posix.setsockopt(
                sockfd,
                posix.SOL.SOCKET,
                posix.SO.REUSEPORT,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }

        var socklen = address.getOsSockLen();
        try posix.bind(sockfd, &address.any, socklen);
        try posix.listen(sockfd, self.kernel_backlog);
        try posix.getsockname(sockfd, &self.listen_address.any, &socklen);
    }

    /// Stop listening. It is still necessary to call `deinit` after stopping listening.
    /// Calling `deinit` will automatically call `close`. It is safe to call `close` when
    /// not listening.
    pub fn close(self: *StreamServer) void {
        if (self.sockfd) |fd| {
            posix.close(fd);
            self.sockfd = null;
            self.listen_address = undefined;
        }
    }
};

fn printUsageExit(execname: []const u8, res: u8) void {
    std.io.getStdErr().writer().print(usage, .{execname}) catch |err| {
        std.log.err("Print usage error: {any}", .{err});
        std.posix.exit(1);
    };
    std.posix.exit(res);
}

pub fn main() !void {

    // allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // args
    var args = try std.process.argsWithAllocator(arena.allocator());
    defer args.deinit();

    const execname = args.next().?;
    var host: []const u8 = Host;
    var port: u16 = Port;
    var addr: std.net.Address = undefined;
    var timeout: u8 = undefined;

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "-h", opt) or std.mem.eql(u8, "--help", opt)) {
            printUsageExit(execname, 0);
        }
        if (std.mem.eql(u8, "--host", opt)) {
            if (args.next()) |arg| {
                host = arg;
                continue;
            } else {
                std.log.err("--host not provided\n", .{});
                return printUsageExit(execname, 1);
            }
        }
        if (std.mem.eql(u8, "--port", opt)) {
            if (args.next()) |arg| {
                port = std.fmt.parseInt(u16, arg, 10) catch |err| {
                    std.log.err("--port {any}\n", .{err});
                    return printUsageExit(execname, 1);
                };
                continue;
            } else {
                std.log.err("--port not provided\n", .{});
                return printUsageExit(execname, 1);
            }
        }
        if (std.mem.eql(u8, "--timeout", opt)) {
            if (args.next()) |arg| {
                timeout = std.fmt.parseInt(u8, arg, 10) catch |err| {
                    std.log.err("--timeout {any}\n", .{err});
                    return printUsageExit(execname, 1);
                };
                continue;
            } else {
                std.log.err("--timeout not provided\n", .{});
                return printUsageExit(execname, 1);
            }
        }
    }
    addr = std.net.Address.parseIp4(host, port) catch |err| {
        std.log.err("address (host:port) {any}\n", .{err});
        return printUsageExit(execname, 1);
    };

    // server
    var srv = StreamServer.init(.{
        .reuse_address = true,
        .reuse_port = true,
        .nonblocking = true,
    });
    defer srv.deinit();

    srv.listen(addr) catch |err| {
        std.log.err("address (host:port) {any}\n", .{err});
        return printUsageExit(execname, 1);
    };
    defer srv.close();
    std.log.info("Listening on: {s}:{d}...", .{ host, port });

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // loop
    var loop = try jsruntime.Loop.init(arena.allocator());
    defer loop.deinit();

    // browser
    var browser = try Browser.init(arena.allocator(), &loop, vm);
    defer browser.deinit();

    // listen
    try server.listen(&browser, &loop, srv.sockfd.?, std.time.ns_per_s * @as(u64, timeout));
}
