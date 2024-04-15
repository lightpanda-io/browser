const std = @import("std");

const public = @import("jsruntime");
const Completion = public.IO.Completion;
const AcceptError = public.IO.AcceptError;
const RecvError = public.IO.RecvError;
const SendError = public.IO.SendError;
const TimeoutError = public.IO.TimeoutError;

const Window = @import("html/window.zig").Window;

const cdp = @import("cdp/cdp.zig");
pub var socket_fd: std.os.socket_t = undefined;

const NoError = error{NoError};
const Error = AcceptError || RecvError || SendError || TimeoutError || cdp.Error || NoError;

// I/O Recv
// --------

pub const Cmd = struct {

    // internal fields
    socket: std.os.socket_t,
    buf: []u8, // only for read operations
    err: ?Error = null,

    // JS fields
    js_env: *public.Env,
    try_catch: public.TryCatch,

    fn cbk(self: *Cmd, completion: *Completion, result: RecvError!usize) void {
        const size = result catch |err| {
            self.err = err;
            return;
        };

        const input = self.buf[0..size];

        // close on exit command
        if (std.mem.eql(u8, input, "exit")) {
            self.err = error.NoError;
            return;
        }

        // input
        if (std.log.defaultLogEnabled(.debug)) {
            std.debug.print("\ninput {s}\n", .{input});
        }

        // cdp
        const res = cdp.do(self.alloc(), input, self) catch |err| {
            if (cdp.isCdpError(err)) |e| {
                self.err = e;
                return;
            }
            @panic(@errorName(err));
        };
        std.log.debug("res {s}", .{res});

        sendAsync(self, res) catch unreachable;

        // continue receving incomming messages asynchronously
        self.loop().io.recv(*Cmd, self, cbk, completion, self.socket, self.buf);
    }

    // shortcuts
    fn alloc(self: *Cmd) std.mem.Allocator {
        return self.js_env.nat_ctx.alloc;
    }

    fn loop(self: *Cmd) *public.Loop {
        return self.js_env.nat_ctx.loop;
    }
};

// I/O Send
// --------

const Send = struct {
    cmd: *Cmd,
    buf: []const u8,

    fn init(ctx: *Cmd, msg: []const u8) !struct {
        ctx: *Send,
        completion: *Completion,
    } {
        // NOTE: it seems we can't use the same completion for concurrent
        // recv and timeout operations, that's why we create a new completion here
        const completion = try ctx.alloc().create(Completion);
        // NOTE: to handle concurrent calls we create each time a new context
        // If no concurrent calls where required we could just use the main CmdCtx
        const sd = try ctx.alloc().create(Send);
        sd.* = .{
            .cmd = ctx,
            .buf = msg,
        };
        return .{ .ctx = sd, .completion = completion };
    }

    fn deinit(self: *Send, completion: *Completion) void {
        self.cmd.alloc().destroy(completion);
        self.cmd.alloc().free(self.buf);
        self.cmd.alloc().destroy(self);
    }

    fn laterCbk(self: *Send, completion: *Completion, result: TimeoutError!void) void {
        std.log.debug("sending after", .{});
        _ = result catch |err| {
            self.cmd.err = err;
            return;
        };

        self.cmd.loop().io.send(*Send, self, Send.asyncCbk, completion, self.cmd.socket, self.buf);
    }

    fn asyncCbk(self: *Send, completion: *Completion, result: SendError!usize) void {
        const size = result catch |err| {
            self.cmd.err = err;
            return;
        };

        std.log.debug("send async {d} bytes", .{size});
        self.deinit(completion);
    }
};

pub fn sendLater(ctx: *Cmd, msg: []const u8, ns: u63) !void {
    const sd = try Send.init(ctx, msg);
    ctx.loop().io.timeout(*Send, sd.ctx, Send.laterCbk, sd.completion, ns);
}

pub fn sendAsync(ctx: *Cmd, msg: []const u8) !void {
    const sd = try Send.init(ctx, msg);
    ctx.loop().io.send(*Send, sd.ctx, Send.asyncCbk, sd.completion, ctx.socket, msg);
}

pub fn sendSync(ctx: *Cmd, msg: []const u8) !void {
    defer ctx.alloc().free(msg);
    const s = try std.os.write(ctx.socket, msg);
    std.log.debug("send sync {d} bytes", .{s});
}

// I/O Accept
// ----------

const Accept = struct {
    cmd: *Cmd,
    socket: std.os.socket_t,

    fn cbk(self: *Accept, completion: *Completion, result: AcceptError!std.os.socket_t) void {
        self.cmd.socket = result catch |err| {
            self.cmd.err = err;
            return;
        };

        // receving incomming messages asynchronously
        self.cmd.loop().io.recv(*Cmd, self.cmd, Cmd.cbk, completion, self.cmd.socket, self.cmd.buf);
    }
};

pub fn execJS(alloc: std.mem.Allocator, js_env: *public.Env) anyerror!void {

    // start JS env
    try js_env.start(alloc);
    defer js_env.stop();

    // alias global as self
    try js_env.attachObject(try js_env.getGlobal(), "self", null);

    // alias global as self and window
    const window = Window.create(null);
    // window.replaceDocument(doc); TODO
    try js_env.bindGlobal(window);

    // add console object
    const console = public.Console{};
    try js_env.addObject(console, "console");

    // JS try cache
    var try_catch = public.TryCatch.init(js_env.*);
    defer try_catch.deinit();

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var input: [1024]u8 = undefined;
    var cmd = Cmd{
        .js_env = js_env,
        .socket = undefined,
        .buf = &input,
        .try_catch = try_catch,
    };
    var accept = Accept{
        .cmd = &cmd,
        .socket = socket_fd,
    };

    // accepting connection asynchronously on internal server
    const loop = js_env.nat_ctx.loop;
    var completion: Completion = undefined;
    loop.io.accept(*Accept, &accept, Accept.cbk, &completion, socket_fd);

    // infinite loop on I/O events, either:
    // - cmd from incoming connection on server socket
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.tick();
        if (loop.cbk_error) {
            if (try try_catch.exception(alloc, js_env.*)) |msg| {
                std.debug.print("\n\rUncaught {s}\n\r", .{msg});
                alloc.free(msg);
            }
            loop.cbk_error = false;
        }
        if (cmd.err) |err| {
            if (err != error.NoError) std.log.err("Server error: {any}", .{err});
            break;
        }
    }
}
