const std = @import("std");

const Ctx = @import("std/http/Client.zig").Ctx;
const Loop = @import("jsruntime").Loop;
const NetworkImpl = Loop.Network(SingleThreaded);

pub const Blocking = struct {
    pub fn connect(
        _: *Blocking,
        comptime CtxT: type,
        ctx: *CtxT,
        comptime cbk: fn (ctx: *CtxT, res: anyerror!void) anyerror!void,
        socket: std.posix.socket_t,
        address: std.net.Address,
    ) void {
        std.posix.connect(socket, &address.any, address.getOsSockLen()) catch |err| {
            std.posix.close(socket);
            cbk(ctx, err) catch |e| {
                ctx.setErr(e);
            };
        };
        cbk(ctx, {}) catch |e| ctx.setErr(e);
    }

    pub fn send(
        _: *Blocking,
        comptime CtxT: type,
        ctx: *CtxT,
        comptime cbk: fn (ctx: *CtxT, res: anyerror!void) anyerror!void,
        socket: std.posix.socket_t,
        buf: []const u8,
    ) void {
        const len = std.posix.write(socket, buf) catch |err| {
            cbk(ctx, err) catch |e| {
                return ctx.setErr(e);
            };
            return ctx.setErr(err);
        };
        ctx.setLen(len);
        cbk(ctx, {}) catch |e| ctx.setErr(e);
    }

    pub fn recv(
        _: *Blocking,
        comptime CtxT: type,
        ctx: *CtxT,
        comptime cbk: fn (ctx: *CtxT, res: anyerror!void) anyerror!void,
        socket: std.posix.socket_t,
        buf: []u8,
    ) void {
        const len = std.posix.read(socket, buf) catch |err| {
            cbk(ctx, err) catch |e| {
                return ctx.setErr(e);
            };
            return ctx.setErr(err);
        };
        ctx.setLen(len);
        cbk(ctx, {}) catch |e| ctx.setErr(e);
    }
};

pub const SingleThreaded = struct {
    impl: NetworkImpl,
    cbk: Cbk,
    ctx: *Ctx,

    const Self = @This();
    const Cbk = *const fn (ctx: *Ctx, res: anyerror!void) anyerror!void;

    pub fn init(loop: *Loop) Self {
        return .{
            .impl = NetworkImpl.init(loop),
            .cbk = undefined,
            .ctx = undefined,
        };
    }

    pub fn connect(
        self: *Self,
        comptime _: type,
        ctx: *Ctx,
        comptime cbk: Cbk,
        socket: std.posix.socket_t,
        address: std.net.Address,
    ) void {
        self.cbk = cbk;
        self.ctx = ctx;
        self.impl.connect(self, socket, address);
    }

    pub fn onConnect(self: *Self, err: ?anyerror) void {
        if (err) |e| return self.ctx.setErr(e);
        self.cbk(self.ctx, {}) catch |e| self.ctx.setErr(e);
    }

    pub fn send(
        self: *Self,
        comptime _: type,
        ctx: *Ctx,
        comptime cbk: Cbk,
        socket: std.posix.socket_t,
        buf: []const u8,
    ) void {
        self.ctx = ctx;
        self.cbk = cbk;
        self.impl.send(self, socket, buf);
    }

    pub fn onSend(self: *Self, ln: usize, err: ?anyerror) void {
        if (err) |e| return self.ctx.setErr(e);
        self.ctx.setLen(ln);
        self.cbk(self.ctx, {}) catch |e| self.ctx.setErr(e);
    }

    pub fn recv(
        self: *Self,
        comptime _: type,
        ctx: *Ctx,
        comptime cbk: Cbk,
        socket: std.posix.socket_t,
        buf: []u8,
    ) void {
        self.ctx = ctx;
        self.cbk = cbk;
        self.impl.receive(self, socket, buf);
    }

    pub fn onReceive(self: *Self, ln: usize, err: ?anyerror) void {
        if (err) |e| return self.ctx.setErr(e);
        self.ctx.setLen(ln);
        self.cbk(self.ctx, {}) catch |e| self.ctx.setErr(e);
    }
};
