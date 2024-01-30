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

    pub fn connect(self: *Conn, socket: std.os.socket_t, address: std.net.Address) !void {
        var cmd = Command{ .impl = undefined };
        cmd.impl = NetworkImpl.init(self.loop, &cmd);
        cmd.impl.connect(socket, address);
        _ = try cmd.wait();
    }

    pub fn send(self: *Conn, socket: std.os.socket_t, buffer: []const u8) !usize {
        var cmd = Command{ .impl = undefined };
        cmd.impl = NetworkImpl.init(self.loop, &cmd);
        cmd.impl.send(socket, buffer);
        return try cmd.wait();
    }

    pub fn receive(self: *Conn, socket: std.os.socket_t, buffer: []u8) !usize {
        var cmd = Command{ .impl = undefined };
        cmd.impl = NetworkImpl.init(self.loop, &cmd);
        cmd.impl.receive(socket, buffer);
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
    return std.os.ConnectError.ConnectionRefused;
}

pub fn tcpConnectToAddress(alloc: std.mem.Allocator, loop: *Loop, addr: net.Address) !Stream {
    const sockfd = try std.os.socket(addr.any.family, std.os.SOCK.STREAM, std.os.IPPROTO.TCP);
    errdefer std.os.closeSocket(sockfd);

    var conn = try alloc.create(Conn);
    conn.* = Conn{ .loop = loop };
    try conn.connect(sockfd, addr);

    return Stream{
        .alloc = alloc,
        .conn = conn,
        .handle = sockfd,
    };
}
