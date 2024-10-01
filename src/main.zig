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

const socket_path = "/tmp/browsercore-server.sock";

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

pub fn main() !void {

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // alloc
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // remove socket file of internal server
    // reuse_address (SO_REUSEADDR flag) does not seems to work on unix socket
    // see: https://gavv.net/articles/unix-socket-reuse/
    // TODO: use a lock file instead
    std.posix.unlink(socket_path) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };

    // server
    const addr = try std.net.Address.initUnix(socket_path);
    var srv = StreamServer.init(.{
        .reuse_address = true,
        .reuse_port = true,
        .nonblocking = true,
    });
    defer srv.deinit();

    try srv.listen(addr);
    defer srv.close();
    std.debug.print("Listening on: {s}...\n", .{socket_path});

    var browser = try Browser.init(arena.allocator());
    defer browser.deinit();

    try server.listen(&browser, srv.sockfd.?);
}
