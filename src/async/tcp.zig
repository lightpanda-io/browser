const std = @import("std");
const net = std.net;
const Stream = @import("stream.zig").Stream;
const Loop = @import("jsruntime").Loop;

const ConnectCmd = struct {
    const Self = @This();

    loop: *Loop,
    socket: std.os.socket_t,
    err: ?anyerror = null,
    done: bool = false,

    fn run(self: *Self, addr: std.net.Address) !void {
        self.loop.connect(*Self, self, callback, self.socket, addr);
    }

    fn callback(self: *Self, _: std.os.socket_t, err: ?anyerror) void {
        self.err = err;
        self.done = true;
    }

    fn wait(self: *Self) !void {
        while (!self.done) try self.loop.tick();
        if (self.err) |err| return err;
    }
};

pub fn tcpConnectToHost(alloc: std.mem.Allocator, loop: *Loop, name: []const u8, port: u16) !Stream {
    // TODO async resolve
    const list = try net.getAddressList(alloc, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        return tcpConnectToAddress(loop, addr) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        };
    }
    return std.os.ConnectError.ConnectionRefused;
}

pub fn tcpConnectToAddress(loop: *Loop, addr: net.Address) !Stream {
    const sockfd = try loop.open(addr.any.family, std.os.SOCK.STREAM, std.os.IPPROTO.TCP);
    errdefer std.os.closeSocket(sockfd);

    var cmd = ConnectCmd{
        .loop = loop,
        .socket = sockfd,
    };
    try cmd.run(addr);
    try cmd.wait();

    return Stream{
        .loop = loop,
        .handle = sockfd,
    };
}
