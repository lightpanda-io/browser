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

const public = @import("jsruntime");
const Completion = public.IO.Completion;
const AcceptError = public.IO.AcceptError;
const RecvError = public.IO.RecvError;
const SendError = public.IO.SendError;
const TimeoutError = public.IO.TimeoutError;

const MsgBuffer = @import("msg.zig").MsgBuffer;
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
    loop: *public.Loop,

    // internal fields
    socket: std.posix.socket_t,
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
            self.loop.io.recv(*Cmd, self, cbk, completion, self.socket, self.buf);
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
        self.msg_buf.read(self.alloc(), input, self, Cmd.do) catch |err| {
            std.log.err("do error: {any}", .{err});
            return;
        };

        // continue receving incomming messages asynchronously
        self.loop.io.recv(*Cmd, self, cbk, completion, self.socket, self.buf);
    }

    // shortcuts
    inline fn alloc(self: *Cmd) std.mem.Allocator {
        // TODO: should we return the allocator from the page instead?
        return self.browser.currentSession().alloc;
    }

    inline fn env(self: Cmd) public.Env {
        return self.browser.currentSession().env;
    }

    fn do(self: *Cmd, cmd: []const u8) anyerror!void {
        const res = cdp.do(self.alloc(), cmd, self) catch |err| {
            if (err == error.DisposeBrowserContext) {
                try self.newSession();
                return;
            }
            return err;
        };

        // send result
        if (!std.mem.eql(u8, res, "")) {
            std.log.debug("res {s}", .{res});
            return sendAsync(self, res);
        }
    }

    fn newSession(self: *Cmd) !void {
        std.log.info("new session", .{});
        try self.browser.newSession(self.alloc(), self.loop);
        const cmd_opaque = @as(*anyopaque, @ptrCast(self));
        try self.browser.currentSession().setInspector(cmd_opaque, Cmd.onInspectorResp, Cmd.onInspectorNotif);
    }

    // Inspector

    pub fn sendInspector(self: *Cmd, msg: []const u8) void {
        if (self.env().getInspector()) |inspector| {
            inspector.send(self.env(), msg);
        }
    }

    pub fn onInspectorResp(cmd_opaque: *anyopaque, _: u32, msg: []const u8) void {
        std.log.debug("onResp biz fn called: {s}", .{msg});
        const aligned = @as(*align(@alignOf(Cmd)) anyopaque, @alignCast(cmd_opaque));
        const self = @as(*Cmd, @ptrCast(aligned));

        const tpl = "{s},\"sessionId\":\"{s}\"}}";
        const msg_open = msg[0 .. msg.len - 1]; // remove closing bracket
        const s = std.fmt.allocPrint(
            self.alloc(),
            tpl,
            .{ msg_open, cdp.ContextSessionID },
        ) catch unreachable;
        defer self.alloc().free(s);

        sendSync(self, s) catch unreachable;
    }

    pub fn onInspectorNotif(cmd_opaque: *anyopaque, msg: []const u8) void {
        std.log.debug("onNotif biz fn called: {s}", .{msg});
        const aligned = @as(*align(@alignOf(Cmd)) anyopaque, @alignCast(cmd_opaque));
        const self = @as(*Cmd, @ptrCast(aligned));

        const tpl = "{s},\"sessionId\":\"{s}\"}}";
        const msg_open = msg[0 .. msg.len - 1]; // remove closing bracket
        const s = std.fmt.allocPrint(
            self.alloc(),
            tpl,
            .{ msg_open, cdp.ContextSessionID },
        ) catch unreachable;
        defer self.alloc().free(s);
        std.log.debug("event: {s}", .{s});

        sendSync(self, s) catch unreachable;
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

        self.cmd.loop.io.send(*Send, self, Send.asyncCbk, completion, self.cmd.socket, self.buf);
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
    ctx.loop.io.timeout(*Send, sd.ctx, Send.laterCbk, sd.completion, ns);
}

pub fn sendAsync(ctx: *Cmd, msg: []const u8) !void {
    const sd = try Send.init(ctx, msg);
    ctx.loop.io.send(*Send, sd.ctx, Send.asyncCbk, sd.completion, ctx.socket, msg);
}

pub fn sendSync(ctx: *Cmd, msg: []const u8) !void {
    const s = try std.posix.write(ctx.socket, msg);
    std.log.debug("send sync {d} bytes", .{s});
}

// I/O Accept
// ----------

const Accept = struct {
    cmd: *Cmd,
    socket: std.posix.socket_t,

    fn cbk(self: *Accept, completion: *Completion, result: AcceptError!std.posix.socket_t) void {
        self.cmd.socket = result catch |err| {
            self.cmd.err = err;
            return;
        };

        // receving incomming messages asynchronously
        self.cmd.loop.io.recv(*Cmd, self.cmd, Cmd.cbk, completion, self.cmd.socket, self.cmd.buf);
    }
};

// Listen
// ------

pub fn listen(browser: *Browser, loop: *public.Loop, socket: std.posix.socket_t) anyerror!void {

    // MsgBuffer
    var msg_buf = try MsgBuffer.init(loop.alloc, BufReadSize * 256); // 256KB
    defer msg_buf.deinit(loop.alloc);

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var ctxInput: [BufReadSize]u8 = undefined;
    var cmd = Cmd{
        .loop = loop,
        .browser = browser,
        .socket = undefined,
        .buf = &ctxInput,
        .msg_buf = &msg_buf,
    };
    const cmd_opaque = @as(*anyopaque, @ptrCast(&cmd));
    try browser.currentSession().setInspector(cmd_opaque, Cmd.onInspectorResp, Cmd.onInspectorNotif);

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
