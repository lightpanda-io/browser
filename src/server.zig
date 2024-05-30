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
const IOError = AcceptError || RecvError || SendError || TimeoutError;
const Error = IOError || std.fmt.ParseIntError || cdp.Error || NoError;

// I/O Recv
// --------

const BufReadSize = 1024; // 1KB
const MaxStdOutSize = 512; // ensure debug msg are not too long

pub const Cmd = struct {

    // internal fields
    socket: std.os.socket_t,
    buf: []u8, // only for read operations
    err: ?Error = null,

    msg_buf: *MsgBuffer,

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
        const input = self.buf[0..size];
        if (std.log.defaultLogEnabled(.debug)) {
            const content = input[0..@min(MaxStdOutSize, size)];
            std.debug.print("\ninput size: {d}, content: {s}\n", .{ size, content });
        }

        // close on exit command
        if (std.mem.eql(u8, input, "exit")) {
            self.err = error.NoError;
            return;
        }

        // read and execute input
        self.msg_buf.read(self.alloc(), input, self, Cmd.do) catch unreachable;

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

    fn do(self: *Cmd, cmd: []const u8) anyerror!void {
        const res = try cdp.do(self.alloc(), cmd, self);

        // send result
        if (!std.mem.eql(u8, res, "")) {
            std.log.debug("res {s}", .{res});
            return sendAsync(self, res);
        }
    }
};

/// MsgBuffer return messages from a raw text read stream,
/// according to the following format `<msg_size>:<msg>`.
/// It handles both:
/// - combined messages in one read
/// - single message in several read (multipart)
/// It is safe (and good practice) to reuse the same MsgBuffer
/// on several reads of the same stream.
const MsgBuffer = struct {
    size: usize = 0,
    buf: []u8,
    pos: usize = 0,

    fn init(alloc: std.mem.Allocator, size: usize) std.mem.Allocator.Error!MsgBuffer {
        const buf = try alloc.alloc(u8, size);
        return .{ .buf = buf };
    }

    fn deinit(self: MsgBuffer, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    fn isFinished(self: *MsgBuffer) bool {
        return self.pos >= self.size;
    }

    fn isEmpty(self: MsgBuffer) bool {
        return self.size == 0 and self.pos == 0;
    }

    fn reset(self: *MsgBuffer) void {
        self.size = 0;
        self.pos = 0;
    }

    // read input
    // - `do_func` is a callback to execute on each message of the input
    // - `data` is a arbitrary payload that will be passed to the callback along with
    // the message itself
    fn read(
        self: *MsgBuffer,
        alloc: std.mem.Allocator,
        input: []const u8,
        data: anytype,
        comptime do_func: fn (data: @TypeOf(data), msg: []const u8) anyerror!void,
    ) !void {
        var _input = input; // make input writable

        while (true) {
            var msg: []const u8 = undefined;

            // msg size
            var msg_size: usize = undefined;
            if (self.isEmpty()) {
                // parse msg size metadata
                const size_pos = std.mem.indexOfScalar(u8, _input, ':').?;
                const size_str = _input[0..size_pos];
                msg_size = try std.fmt.parseInt(u32, size_str, 10);
                _input = _input[size_pos + 1 ..];
            } else {
                msg_size = self.size;
            }

            // multipart
            const is_multipart = !self.isEmpty() or _input.len < msg_size;
            if (is_multipart) {

                // set msg size on empty MsgBuffer
                if (self.isEmpty()) {
                    self.size = msg_size;
                }

                // get the new position of the cursor
                const new_pos = self.pos + _input.len;

                // check if the current input can fit in MsgBuffer
                if (new_pos > self.buf.len) {
                    // max_size is the max between msg size and current new cursor position
                    const max_size = @max(self.size, new_pos);
                    // resize the MsgBuffer to fit
                    self.buf = try alloc.realloc(self.buf, max_size);
                }

                // copy the current input into MsgBuffer
                @memcpy(self.buf[self.pos..new_pos], _input[0..]);

                // set the new cursor position
                self.pos = new_pos;

                // if multipart is not finished, go fetch the next input
                if (!self.isFinished()) return;

                // otherwhise multipart is finished, use its buffer as input
                _input = self.buf[0..self.pos];
                self.reset();
            }

            // handle several JSON msg in 1 read
            const is_combined = _input.len > msg_size;
            msg = _input[0..msg_size];
            std.log.debug("msg: {s}", .{msg[0..@min(MaxStdOutSize, msg_size)]});
            if (is_combined) {
                _input = _input[msg_size..];
            }

            try @call(.auto, do_func, .{ data, msg });

            if (!is_combined) break;
        }
    }
};

fn doTest(nb: *u8, _: []const u8) anyerror!void {
    nb.* += 1;
}

test "MsgBuffer" {
    const Case = struct {
        input: []const u8,
        nb: u8,
    };
    const alloc = std.testing.allocator;
    const cases = [_]Case{
        // simple
        .{ .input = "2:ok", .nb = 1 },
        // combined
        .{ .input = "2:ok3:foo7:bar2:ok", .nb = 3 }, // "bar2:ok" is a message, no need to escape "2:" here
        // multipart
        .{ .input = "9:multi", .nb = 0 },
        .{ .input = "part", .nb = 1 },
        // multipart & combined
        .{ .input = "9:multi", .nb = 0 },
        .{ .input = "part2:ok", .nb = 2 },
        // several multipart
        .{ .input = "23:multi", .nb = 0 },
        .{ .input = "several", .nb = 0 },
        .{ .input = "complex", .nb = 0 },
        .{ .input = "part", .nb = 1 },
        // combined & multipart
        .{ .input = "2:ok9:multi", .nb = 1 },
        .{ .input = "part", .nb = 1 },
    };
    var nb: u8 = undefined;
    var msg_buf = try MsgBuffer.init(alloc, 10);
    defer msg_buf.deinit(alloc);
    for (cases) |case| {
        nb = 0;
        try msg_buf.read(alloc, case.input, &nb, doTest);
        try std.testing.expect(nb == case.nb);
    }
}

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
    const loop = browser.currentSession().loop;

    // MsgBuffer
    var msg_buf = try MsgBuffer.init(loop.alloc, BufReadSize * 256); // 256KB
    defer msg_buf.deinit(loop.alloc);

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var ctxInput: [BufReadSize]u8 = undefined;
    var cmd = Cmd{
        .browser = browser,
        .socket = undefined,
        .buf = &ctxInput,
        .msg_buf = &msg_buf,
    };
    var accept = Accept{
        .cmd = &cmd,
        .socket = socket,
    };

    // accepting connection asynchronously on internal server
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
