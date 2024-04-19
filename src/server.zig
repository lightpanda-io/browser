const std = @import("std");

const public = @import("jsruntime");
const Completion = public.IO.Completion;
const AcceptError = public.IO.AcceptError;
const RecvError = public.IO.RecvError;
const SendError = public.IO.SendError;
const TimeoutError = public.IO.TimeoutError;

const Browser = @import("browser/browser.zig").Browser;

const cdp = @import("cdp/cdp.zig");

const NoError = error{NoError};
const Error = AcceptError || RecvError || SendError || TimeoutError || cdp.Error || NoError;

// I/O Recv
// --------

pub const Cmd = struct {

    // internal fields
    socket: std.os.socket_t,
    buf: []u8, // only for read operations
    err: ?Error = null,

    // CDP
    state: cdp.State = .{},

    // JS fields
    browser: *Browser, // TODO: is pointer mandatory here?
    // try_catch: public.TryCatch, // TODO

    fn cbk(self: *Cmd, completion: *Completion, result: RecvError!usize) void {
        const size = result catch |err| {
            self.err = err;
            return;
        };

        if (size == 0) {
            // continue receving incomming messages asynchronously
            self.loop().io.recv(*Cmd, self, cbk, completion, self.socket, self.buf);
            return;
        }

        // input
        var input = self.buf[0..size];
        if (std.log.defaultLogEnabled(.debug)) {
            std.debug.print("\ninput size: {d}, content: {s}\n", .{ size, input });
        }

        // close on exit command
        if (std.mem.eql(u8, input, "exit")) {
            self.err = error.NoError;
            return;
        }

        // cmds
        var cmd: []const u8 = undefined;
        while (true) {

            // handle several JSON msg in 1 read
            const pos = std.mem.indexOf(u8, input, "}{");
            if (pos) |p| {
                cmd = input[0 .. p + 1];
                input = input[p + 1 ..];
            } else {
                cmd = input;
            }

            // cdp
            const res = cdp.do(self.alloc(), cmd, self) catch |err| {
                if (cdp.isCdpError(err)) |e| {
                    self.err = e;
                    return;
                }
                @panic(@errorName(err));
            };

            // send result
            if (!std.mem.eql(u8, res, "")) {
                std.log.debug("res {s}", .{res});
                sendAsync(self, res) catch unreachable;
            }

            if (pos == null) break;

            // TODO: handle 1 read smaller than a complete JSON msg
        }

        // continue receving incomming messages asynchronously
        self.loop().io.recv(*Cmd, self, cbk, completion, self.socket, self.buf);
    }

    // shortcuts
    fn alloc(self: *Cmd) std.mem.Allocator {
        // TODO: should we return the allocator from the page instead?
        return self.browser.currentSession().alloc;
    }

    fn loop(self: *Cmd) public.Loop {
        // TODO: pointer instead?
        return self.browser.currentSession().loop;
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

// Listen
// ------

pub fn listen(browser: *Browser, socket: std.os.socket_t) anyerror!void {

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var input: [1024]u8 = undefined;
    var cmd = Cmd{
        .browser = browser,
        .socket = undefined,
        .buf = &input,
    };
    var accept = Accept{
        .cmd = &cmd,
        .socket = socket,
    };

    // accepting connection asynchronously on internal server
    const loop = browser.currentSession().loop;
    var completion: Completion = undefined;
    loop.io.accept(*Accept, &accept, Accept.cbk, &completion, socket);

    // infinite loop on I/O events, either:
    // - cmd from incoming connection on server socket
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.tick();
        if (loop.cbk_error) {
            std.log.err("JS error", .{});
            // if (try try_catch.exception(alloc, js_env.*)) |msg| {
            //     std.debug.print("\n\rUncaught {s}\n\r", .{msg});
            //     alloc.free(msg);
            // }
            // loop.cbk_error = false;
        }
        if (cmd.err) |err| {
            if (err != error.NoError) std.log.err("Server error: {any}", .{err});
            break;
        }
    }
}
