const std = @import("std");
const Client = @import("std/http/Client.zig");

const Stack = @import("stack.zig");

const Res = fn (ctx: *Ctx, res: ?anyerror) anyerror!void;

pub const Blocking = struct {
    pub fn connect(
        _: *Blocking,
        comptime ctxT: type,
        ctx: *ctxT,
        comptime cbk: Res,
        socket: std.os.socket_t,
        address: std.net.Address,
    ) void {
        std.os.connect(socket, &address.any, address.getOsSockLen()) catch |err| {
            std.os.closeSocket(socket);
            _ = cbk(ctx, err);
            return;
        };
        ctx.socket = socket;
        _ = cbk(ctx, null);
    }
};

const CtxStack = Stack(Res);

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    stack: ?*CtxStack = null,

    // TCP ctx
    client: *Client = undefined,
    addr_current: usize = undefined,
    list: *std.net.AddressList = undefined,
    socket: std.os.socket_t = undefined,
    Stream: std.net.Stream = undefined,
    host: []const u8 = undefined,
    port: u16 = undefined,
    protocol: Client.Connection.Protocol = undefined,
    conn: *Client.Connection = undefined,
    uri: std.Uri = undefined,
    headers: std.http.Headers = undefined,
    method: std.http.Method = undefined,
    options: Client.RequestOptions = undefined,
    request: Client.Request = undefined,

    err: ?anyerror,

    pub fn init(alloc: std.mem.Allocator) Ctx {
        return .{ .alloc = alloc };
    }

    pub fn push(self: *Ctx, function: CtxStack.Fn) !void {
        if (self.stack) |stack| {
            return try stack.push(self.alloc, function);
        }
        self.stack = try CtxStack.init(self.alloc, function);
    }

    pub fn next(self: *Ctx, err: ?anyerror) !void {
        if (self.stack) |stack| {
            const last = stack.next == null;
            const function = stack.pop(self.alloc, stack);
            const res = @call(.auto, function, .{ self, err });
            if (last) {
                self.stack = null;
                self.alloc.destroy(stack);
            }
            return res;
        }
        self.err = err;
    }
};
