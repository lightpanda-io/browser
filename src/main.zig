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
const builtin = @import("builtin");

const jsruntime = @import("jsruntime");

const Browser = @import("browser/browser.zig").Browser;
const server = @import("server.zig");

const parser = @import("netsurf");
const apiweb = @import("apiweb.zig");

pub const Types = jsruntime.reflect(apiweb.Interfaces);
pub const UserContext = apiweb.UserContext;
pub const IO = @import("asyncio").Wrapper(jsruntime.Loop);

const log = std.log.scoped(.cli);

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

    fn setSockOpt(fd: posix.socket_t, level: i32, option: u32, value: c_int) !void {
        try posix.setsockopt(fd, level, option, &std.mem.toBytes(value));
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

        // socket options
        if (self.reuse_address) {
            try setSockOpt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
        }
        if (@hasDecl(posix.SO, "REUSEPORT") and self.reuse_port) {
            try setSockOpt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEPORT, 1);
        }
        if (builtin.target.os.tag == .linux) { // posix.TCP not available on MacOS
            // WARNING: disable Nagle's alogrithm to avoid latency issues
            try setSockOpt(sockfd, posix.IPPROTO.TCP, posix.TCP.NODELAY, 1);
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

const usage =
    \\usage: {s} [options] [URL]
    \\
    \\  start Lightpanda browser
    \\
    \\  * if an url is provided the browser will fetch the page and exit
    \\  * otherwhise the browser starts a CDP server
    \\
    \\  -h, --help      Print this help message and exit.
    \\  --host          Host of the CDP server (default "127.0.0.1")
    \\  --port          Port of the CDP server (default "3245")
    \\  --timeout       Timeout for incoming connections of the CDP server (in seconds, default "3")
    \\  --dump          Dump document in stdout (fetch mode only)
    \\
;

fn printUsageExit(execname: []const u8, res: u8) anyerror {
    std.io.getStdErr().writer().print(usage, .{execname}) catch |err| {
        std.log.err("Print usage error: {any}", .{err});
        return error.Cli;
    };
    if (res == 1) return error.Usage;
    return error.NoError;
}

const CliModeTag = enum {
    server,
    fetch,
};

const CliMode = union(CliModeTag) {
    server: Server,
    fetch: Fetch,

    const Server = struct {
        execname: []const u8 = undefined,
        args: *std.process.ArgIterator = undefined,
        addr: std.net.Address = undefined,
        host: []const u8 = Host,
        port: u16 = Port,
        timeout: u8 = Timeout,

        // default options
        const Host = "127.0.0.1";
        const Port = 3245;
        const Timeout = 3; // in seconds
    };

    const Fetch = struct {
        execname: []const u8 = undefined,
        args: *std.process.ArgIterator = undefined,
        url: []const u8 = "",
        dump: bool = false,
    };

    fn init(alloc: std.mem.Allocator, args: *std.process.ArgIterator) !CliMode {
        args.* = try std.process.argsWithAllocator(alloc);
        errdefer args.deinit();

        const execname = args.next().?;
        var default_mode: CliModeTag = .server;

        var _server = Server{};
        var _fetch = Fetch{};

        while (args.next()) |opt| {
            if (std.mem.eql(u8, "-h", opt) or std.mem.eql(u8, "--help", opt)) {
                return printUsageExit(execname, 0);
            }
            if (std.mem.eql(u8, "--dump", opt)) {
                _fetch.dump = true;
                continue;
            }
            if (std.mem.eql(u8, "--host", opt)) {
                if (args.next()) |arg| {
                    _server.host = arg;
                    continue;
                } else {
                    std.log.err("--host not provided\n", .{});
                    return printUsageExit(execname, 1);
                }
            }
            if (std.mem.eql(u8, "--port", opt)) {
                if (args.next()) |arg| {
                    _server.port = std.fmt.parseInt(u16, arg, 10) catch |err| {
                        log.err("--port {any}\n", .{err});
                        return printUsageExit(execname, 1);
                    };
                    continue;
                } else {
                    log.err("--port not provided\n", .{});
                    return printUsageExit(execname, 1);
                }
            }
            if (std.mem.eql(u8, "--timeout", opt)) {
                if (args.next()) |arg| {
                    _server.timeout = std.fmt.parseInt(u8, arg, 10) catch |err| {
                        log.err("--timeout {any}\n", .{err});
                        return printUsageExit(execname, 1);
                    };
                    continue;
                } else {
                    log.err("--timeout not provided\n", .{});
                    return printUsageExit(execname, 1);
                }
            }

            // unknown option
            if (std.mem.startsWith(u8, opt, "--")) {
                log.err("unknown option\n", .{});
                return printUsageExit(execname, 1);
            }

            // other argument is considered to be an URL, ie. fetch mode
            default_mode = .fetch;

            // allow only one url
            if (_fetch.url.len != 0) {
                log.err("more than 1 url provided\n", .{});
                return printUsageExit(execname, 1);
            }

            _fetch.url = opt;
        }

        if (default_mode == .server) {

            // server mode
            _server.addr = std.net.Address.parseIp4(_server.host, _server.port) catch |err| {
                log.err("address (host:port) {any}\n", .{err});
                return printUsageExit(execname, 1);
            };
            _server.execname = execname;
            _server.args = args;
            return CliMode{ .server = _server };
        } else {

            // fetch mode
            _fetch.execname = execname;
            _fetch.args = args;
            return CliMode{ .fetch = _fetch };
        }
    }

    fn deinit(self: CliMode) void {
        switch (self) {
            inline .server, .fetch => |*_mode| {
                _mode.args.deinit();
            },
        }
    }
};

pub fn main() !void {

    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the page allocator
    var alloc: std.mem.Allocator = undefined;
    var _gpa: ?std.heap.GeneralPurposeAllocator(.{}) = null;
    if (builtin.mode == .Debug) {
        _gpa = std.heap.GeneralPurposeAllocator(.{}){};
        alloc = _gpa.?.allocator();
    } else {
        alloc = std.heap.page_allocator;
    }
    defer {
        if (_gpa) |*gpa| {
            switch (gpa.deinit()) {
                .ok => std.debug.print("No memory leaks\n", .{}),
                .leak => @panic("Memory leak"),
            }
        }
    }

    // args
    var args: std.process.ArgIterator = undefined;
    const cli_mode = CliMode.init(alloc, &args) catch |err| {
        if (err == error.NoError) {
            std.posix.exit(0);
        } else {
            std.posix.exit(1);
        }
        return;
    };
    defer cli_mode.deinit();

    switch (cli_mode) {
        .server => |mode| {

            // server
            var srv = StreamServer.init(.{
                .reuse_address = true,
                .reuse_port = true,
                .nonblocking = true,
            });
            defer srv.deinit();

            srv.listen(mode.addr) catch |err| {
                log.err("address (host:port) {any}\n", .{err});
                return printUsageExit(mode.execname, 1);
            };
            defer srv.close();
            log.info("Server mode: listening on {s}:{d}...", .{ mode.host, mode.port });

            // loop
            var loop = try jsruntime.Loop.init(alloc);
            defer loop.deinit();

            // listen
            try server.listen(alloc, &loop, srv.sockfd.?, std.time.ns_per_s * @as(u64, mode.timeout));
        },

        .fetch => |mode| {
            log.debug("Fetch mode: url {s}, dump {any}", .{ mode.url, mode.dump });

            // vm
            const vm = jsruntime.VM.init();
            defer vm.deinit();

            // loop
            var loop = try jsruntime.Loop.init(alloc);
            defer loop.deinit();

            // browser
            var browser = Browser{};
            try Browser.init(&browser, alloc, &loop, vm);
            defer browser.deinit();

            // page
            const page = try browser.session.createPage();

            _ = page.navigate(mode.url, null) catch |err| switch (err) {
                error.UnsupportedUriScheme, error.UriMissingHost => {
                    log.err("'{s}' is not a valid URL ({any})\n", .{ mode.url, err });
                    return printUsageExit(mode.execname, 1);
                },
                else => {
                    log.err("'{s}' fetching error ({any})s\n", .{ mode.url, err });
                    return printUsageExit(mode.execname, 1);
                },
            };

            try page.wait();

            // dump
            if (mode.dump) {
                try page.dump(std.io.getStdOut());
            }
        },
    }
}
