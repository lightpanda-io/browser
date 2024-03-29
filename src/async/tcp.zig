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
const net = std.net;
const Stream = @import("stream.zig").Stream;
const Loop = @import("jsruntime").Loop;
const NetworkImpl = Loop.Network(Conn.Command);

// Conn is a TCP connection using jsruntime Loop async I/O.
// connect, send and receive are blocking, but use async I/O in the background.
// Client doesn't own the socket used for the connection, the caller is
// responsible for closing it.
pub const Conn = struct {
    const Command = struct {
        impl: NetworkImpl,

        done: bool = false,
        err: ?anyerror = null,
        ln: usize = 0,

        fn ok(self: *Command, err: ?anyerror, ln: usize) void {
            self.err = err;
            self.ln = ln;
            self.done = true;
        }

        fn wait(self: *Command) !usize {
            while (!self.done) try self.impl.tick();

            if (self.err) |err| return err;
            return self.ln;
        }
        pub fn onConnect(self: *Command, err: ?anyerror) void {
            self.ok(err, 0);
        }
        pub fn onSend(self: *Command, ln: usize, err: ?anyerror) void {
            self.ok(err, ln);
        }
        pub fn onReceive(self: *Command, ln: usize, err: ?anyerror) void {
            self.ok(err, ln);
        }
    };

    loop: *Loop,

    pub fn connect(self: *Conn, socket: std.posix.socket_t, address: std.net.Address) !void {
        var cmd = Command{ .impl = NetworkImpl.init(self.loop) };
        cmd.impl.connect(&cmd, socket, address);
        _ = try cmd.wait();
    }

    pub fn send(self: *Conn, socket: std.posix.socket_t, buffer: []const u8) !usize {
        var cmd = Command{ .impl = NetworkImpl.init(self.loop) };
        cmd.impl.send(&cmd, socket, buffer);
        return try cmd.wait();
    }

    pub fn receive(self: *Conn, socket: std.posix.socket_t, buffer: []u8) !usize {
        var cmd = Command{ .impl = NetworkImpl.init(self.loop) };
        cmd.impl.receive(&cmd, socket, buffer);
        return try cmd.wait();
    }
};

pub fn tcpConnectToHost(alloc: std.mem.Allocator, loop: *Loop, name: []const u8, port: u16) !Stream {
    // TODO async resolve
    const list = try net.getAddressList(alloc, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        return tcpConnectToAddress(alloc, loop, addr) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        };
    }
    return std.posix.ConnectError.ConnectionRefused;
}

pub fn tcpConnectToAddress(alloc: std.mem.Allocator, loop: *Loop, addr: net.Address) !Stream {
    const sockfd = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(sockfd);

    var conn = try alloc.create(Conn);
    conn.* = Conn{ .loop = loop };
    try conn.connect(sockfd, addr);

    return Stream{
        .alloc = alloc,
        .conn = conn,
        .handle = sockfd,
    };
}
