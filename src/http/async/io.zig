const std = @import("std");

pub const IO = @import("jsruntime").IO;

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

pub fn SingleThreaded(comptime CtxT: type) type {
    return struct {
        io: *IO,
        completion: IO.Completion,
        ctx: *CtxT,
        cbk: CbkT,

        count: u32 = 0,

        const CbkT = *const fn (ctx: *CtxT, res: anyerror!void) anyerror!void;

        const Self = @This();

        pub fn init(io: *IO) Self {
            return .{
                .io = io,
                .completion = undefined,
                .ctx = undefined,
                .cbk = undefined,
            };
        }

        pub fn connect(
            self: *Self,
            comptime _: type,
            ctx: *CtxT,
            comptime cbk: CbkT,
            socket: std.posix.socket_t,
            address: std.net.Address,
        ) void {
            self.ctx = ctx;
            self.cbk = cbk;
            self.count += 1;
            self.io.connect(*Self, self, Self.connectCbk, &self.completion, socket, address);
        }

        fn connectCbk(self: *Self, _: *IO.Completion, result: IO.ConnectError!void) void {
            defer self.count -= 1;
            _ = result catch |e| return self.ctx.setErr(e);
            self.cbk(self.ctx, {}) catch |e| self.ctx.setErr(e);
        }

        pub fn send(
            self: *Self,
            comptime _: type,
            ctx: *CtxT,
            comptime cbk: CbkT,
            socket: std.posix.socket_t,
            buf: []const u8,
        ) void {
            self.ctx = ctx;
            self.cbk = cbk;
            self.count += 1;
            self.io.send(*Self, self, Self.sendCbk, &self.completion, socket, buf);
        }

        fn sendCbk(self: *Self, _: *IO.Completion, result: IO.SendError!usize) void {
            defer self.count -= 1;
            const ln = result catch |e| return self.ctx.setErr(e);
            self.ctx.setLen(ln);
            self.cbk(self.ctx, {}) catch |e| self.ctx.setErr(e);
        }

        pub fn recv(
            self: *Self,
            comptime _: type,
            ctx: *CtxT,
            comptime cbk: CbkT,
            socket: std.posix.socket_t,
            buf: []u8,
        ) void {
            self.ctx = ctx;
            self.cbk = cbk;
            self.count += 1;
            self.io.recv(*Self, self, Self.receiveCbk, &self.completion, socket, buf);
        }

        fn receiveCbk(self: *Self, _: *IO.Completion, result: IO.RecvError!usize) void {
            defer self.count -= 1;
            const ln = result catch |e| return self.ctx.setErr(e);
            self.ctx.setLen(ln);
            self.cbk(self.ctx, {}) catch |e| self.ctx.setErr(e);
        }

        pub fn isDone(self: *Self) bool {
            return self.count == 0;
        }
    };
}
