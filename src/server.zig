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
const CloseError = public.IO.CloseError;
const TimeoutError = public.IO.TimeoutError;

const MsgBuffer = @import("msg.zig").MsgBuffer;
const Browser = @import("browser/browser.zig").Browser;
const cdp = @import("cdp/cdp.zig");

const NoError = error{NoError};
const IOError = AcceptError || RecvError || SendError || CloseError || TimeoutError;
const Error = IOError || std.fmt.ParseIntError || cdp.Error || NoError;

const TimeoutCheck = std.time.ns_per_ms * 100;
const TimeoutRead = std.time.ns_per_s * 3; // TODO: cli option

// I/O Main
// --------

const BufReadSize = 1024; // 1KB
const MaxStdOutSize = 512; // ensure debug msg are not too long

pub const Ctx = struct {
    loop: *public.Loop,

    // internal fields
    accept_socket: std.posix.socket_t,
    conn_socket: std.posix.socket_t = undefined,
    read_buf: []u8, // only for read operations
    msg_buf: *MsgBuffer,
    err: ?Error = null,

    // I/O fields
    conn_completion: *Completion,
    timeout_completion: *Completion,
    last_active: ?std.time.Instant = null,

    // CDP
    state: cdp.State = .{},

    // JS fields
    browser: *Browser, // TODO: is pointer mandatory here?
    sessionNew: bool,
    // try_catch: public.TryCatch, // TODO

    // callbacks
    // ---------

    fn acceptCbk(self: *Ctx, completion: *Completion, result: AcceptError!std.posix.socket_t) void {
        std.debug.assert(completion == self.conn_completion);

        self.conn_socket = result catch |err| {
            self.err = err;
            return;
        };

        // set connection timestamp and timeout
        self.last_active = std.time.Instant.now() catch |err| {
            std.log.err("accept timestamp error: {any}", .{err});
            return;
        };
        self.loop.io.timeout(*Ctx, self, Ctx.timeoutCbk, self.timeout_completion, TimeoutCheck);

        // receving incomming messages asynchronously
        self.loop.io.recv(*Ctx, self, Ctx.readCbk, self.conn_completion, self.conn_socket, self.read_buf);
    }

    fn readCbk(self: *Ctx, completion: *Completion, result: RecvError!usize) void {
        std.debug.assert(completion == self.conn_completion);

        const size = result catch |err| {
            self.err = err;
            return;
        };

        if (size == 0) {
            // continue receving incomming messages asynchronously
            self.loop.io.recv(*Ctx, self, Ctx.readCbk, self.conn_completion, self.conn_socket, self.read_buf);
            return;
        }

        // input
        if (std.log.defaultLogEnabled(.debug)) {
            const content = input[0..@min(MaxStdOutSize, size)];
            std.debug.print("\ninput size: {d}, content: {s}\n", .{ size, content });
        }
        const input = self.read_buf[0..size];

        // read and execute input
        self.msg_buf.read(self.alloc(), input, self, Ctx.do) catch |err| {
            if (err != error.Closed) {
                std.log.err("do error: {any}", .{err});
            }
            return;
        };

        // set connection timestamp
        self.last_active = std.time.Instant.now() catch |err| {
            std.log.err("read timestamp error: {any}", .{err});
            return;
        };

        // continue receving incomming messages asynchronously
        self.loop.io.recv(*Ctx, self, Ctx.readCbk, self.conn_completion, self.conn_socket, self.read_buf);
    }

    fn timeoutCbk(self: *Ctx, completion: *Completion, result: TimeoutError!void) void {
        std.debug.assert(completion == self.timeout_completion);

        _ = result catch |err| {
            self.err = err;
            return;
        };

        if (self.isClosed()) {
            // conn is already closed, ignore timeout
            return;
        }

        // check time since last read
        const now = std.time.Instant.now() catch |err| {
            std.log.err("timeout timestamp error: {any}", .{err});
            return;
        };

        if (now.since(self.last_active.?) > TimeoutRead) {
            // closing
            std.log.debug("conn timeout, closing...", .{});

            // NOTE: we should cancel the current read
            // but it seems that's just closing the connection is enough
            // (and cancel does not work on MacOS)

            // close current connection
            self.loop.io.close(*Ctx, self, Ctx.closeCbk, self.timeout_completion, self.conn_socket);
            return;
        }

        // continue checking timeout
        self.loop.io.timeout(*Ctx, self, Ctx.timeoutCbk, self.timeout_completion, TimeoutCheck);
    }

    fn closeCbk(self: *Ctx, completion: *Completion, result: CloseError!void) void {
        _ = completion;
        // NOTE: completion can be either self.conn_completion or self.timeout_completion

        _ = result catch |err| {
            self.err = err;
            return;
        };

        // conn is closed
        self.last_active = null;

        // restart a new browser session in case of re-connect
        if (!self.sessionNew) {
            self.newSession() catch |err| {
                std.log.err("new session error: {any}", .{err});
                return;
            };
        }

        std.log.debug("conn closed", .{});
        std.log.debug("accepting new conn...", .{});

        // continue accepting incoming requests
        self.loop.io.accept(*Ctx, self, Ctx.acceptCbk, self.conn_completion, self.accept_socket);
    }

    // shortcuts
    // ---------

    inline fn isClosed(self: *Ctx) bool {
        // last_active is first saved on acceptCbk
        return self.last_active == null;
    }

    // allocator of the current session
    inline fn alloc(self: *Ctx) std.mem.Allocator {
        return self.browser.currentSession().alloc;
    }

    // JS env of the current session
    inline fn env(self: Ctx) public.Env {
        return self.browser.currentSession().env;
    }

    // actions
    // -------

    fn do(self: *Ctx, cmd: []const u8) anyerror!void {

        // close cmd
        if (std.mem.eql(u8, cmd, "close")) {
            // close connection
            std.log.debug("close cmd, closing...", .{});
            self.loop.io.close(*Ctx, self, Ctx.closeCbk, self.conn_completion, self.conn_socket);
            return error.Closed;
        }

        if (self.sessionNew) self.sessionNew = false;

        const res = cdp.do(self.alloc(), cmd, self) catch |err| {

            // cdp end cmd
            if (err == error.DisposeBrowserContext) {
                // restart a new browser session
                std.log.debug("cdp end cmd", .{});
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

    fn newSession(self: *Ctx) !void {
        try self.browser.newSession(self.alloc(), self.loop);
        const ctx_opaque = @as(*anyopaque, @ptrCast(self));
        try self.browser.currentSession().setInspector(ctx_opaque, Ctx.onInspectorResp, Ctx.onInspectorNotif);
        self.sessionNew = true;
        std.log.debug("new session", .{});
    }

    // inspector
    // ---------

    pub fn sendInspector(self: *Ctx, msg: []const u8) void {
        if (self.env().getInspector()) |inspector| {
            inspector.send(self.env(), msg);
        }
    }

    pub fn onInspectorResp(cmd_opaque: *anyopaque, _: u32, msg: []const u8) void {
        std.log.debug("onResp biz fn called: {s}", .{msg});
        const aligned = @as(*align(@alignOf(Ctx)) anyopaque, @alignCast(cmd_opaque));
        const self = @as(*Ctx, @ptrCast(aligned));

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
        const aligned = @as(*align(@alignOf(Ctx)) anyopaque, @alignCast(cmd_opaque));
        const self = @as(*Ctx, @ptrCast(aligned));

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
    ctx: *Ctx,
    buf: []const u8,

    fn init(ctx: *Ctx, msg: []const u8) !struct {
        ctx: *Send,
        completion: *Completion,
    } {
        // NOTE: it seems we can't use the same completion for concurrent
        // recv and timeout operations, that's why we create a new completion here
        const completion = try ctx.alloc().create(Completion);
        // NOTE: to handle concurrent calls we create each time a new context
        // If no concurrent calls where required we could just use the main Ctx
        const sd = try ctx.alloc().create(Send);
        sd.* = .{
            .ctx = ctx,
            .buf = msg,
        };
        return .{ .ctx = sd, .completion = completion };
    }

    fn deinit(self: *Send, completion: *Completion) void {
        self.ctx.alloc().destroy(completion);
        self.ctx.alloc().free(self.buf);
        self.ctx.alloc().destroy(self);
    }

    fn laterCbk(self: *Send, completion: *Completion, result: TimeoutError!void) void {
        std.log.debug("sending after", .{});
        _ = result catch |err| {
            self.ctx.err = err;
            return;
        };

        self.ctx.loop.io.send(*Send, self, Send.asyncCbk, completion, self.ctx.socket, self.buf);
    }

    fn asyncCbk(self: *Send, completion: *Completion, result: SendError!usize) void {
        const size = result catch |err| {
            self.ctx.err = err;
            return;
        };

        std.log.debug("send async {d} bytes", .{size});
        self.deinit(completion);
    }
};

pub fn sendLater(ctx: *Ctx, msg: []const u8, ns: u63) !void {
    const sd = try Send.init(ctx, msg);
    ctx.loop.io.timeout(*Send, sd.ctx, Send.laterCbk, sd.completion, ns);
}

pub fn sendAsync(ctx: *Ctx, msg: []const u8) !void {
    const sd = try Send.init(ctx, msg);
    ctx.loop.io.send(*Send, sd.ctx, Send.asyncCbk, sd.completion, ctx.conn_socket, msg);
}

pub fn sendSync(ctx: *Ctx, msg: []const u8) !void {
    const s = try std.posix.write(ctx.conn_socket, msg);
    std.log.debug("send sync {d} bytes", .{s});
}

// Listen
// ------

pub fn listen(browser: *Browser, loop: *public.Loop, server_socket: std.posix.socket_t) anyerror!void {

    // create buffers
    var read_buf: [BufReadSize]u8 = undefined;
    var msg_buf = try MsgBuffer.init(loop.alloc, BufReadSize * 256); // 256KB
    defer msg_buf.deinit(loop.alloc);

    // create I/O completions
    var conn_completion: Completion = undefined;
    var timeout_completion: Completion = undefined;

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var ctx = Ctx{
        .loop = loop,
        .browser = browser,
        .sessionNew = true,
        .read_buf = &read_buf,
        .msg_buf = &msg_buf,
        .accept_socket = server_socket,
        .conn_completion = &conn_completion,
        .timeout_completion = &timeout_completion,
    };
    const ctx_opaque = @as(*anyopaque, @ptrCast(ctx));
    try browser.currentSession().setInspector(ctx_opaque, Ctx.onInspectorResp, Ctx.onInspectorNotif);

    // accepting connection asynchronously on internal server
    std.log.debug("accepting new conn...", .{});
    loop.io.accept(*Ctx, &ctx, Ctx.acceptCbk, ctx.conn_completion, ctx.accept_socket);

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
        if (ctx.err) |err| {
            if (err != error.NoError) std.log.err("Server error: {any}", .{err});
            break;
        }
    }
}
