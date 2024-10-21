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

const jsruntime = @import("jsruntime");
const Completion = jsruntime.IO.Completion;
const AcceptError = jsruntime.IO.AcceptError;
const RecvError = jsruntime.IO.RecvError;
const SendError = jsruntime.IO.SendError;
const CloseError = jsruntime.IO.CloseError;
const TimeoutError = jsruntime.IO.TimeoutError;

const MsgBuffer = @import("msg.zig").MsgBuffer;
const Browser = @import("browser/browser.zig").Browser;
const cdp = @import("cdp/cdp.zig");

const NoError = error{NoError};
const IOError = AcceptError || RecvError || SendError || CloseError || TimeoutError;
const Error = IOError || std.fmt.ParseIntError || cdp.Error || NoError;

const TimeoutCheck = std.time.ns_per_ms * 100;

const log = std.log.scoped(.server);

// I/O Main
// --------

const BufReadSize = 1024; // 1KB
const MaxStdOutSize = 512; // ensure debug msg are not too long

pub const Ctx = struct {
    loop: *jsruntime.Loop,

    // internal fields
    accept_socket: std.posix.socket_t,
    conn_socket: std.posix.socket_t = undefined,
    read_buf: []u8, // only for read operations
    msg_buf: *MsgBuffer,
    err: ?Error = null,

    // I/O fields
    conn_completion: *Completion,
    timeout_completion: *Completion,
    timeout: u64,
    last_active: ?std.time.Instant = null,

    // CDP
    state: cdp.State = .{},

    // JS fields
    browser: *Browser, // TODO: is pointer mandatory here?
    sessionNew: bool,
    // try_catch: jsruntime.TryCatch, // TODO

    // callbacks
    // ---------

    fn acceptCbk(
        self: *Ctx,
        completion: *Completion,
        result: AcceptError!std.posix.socket_t,
    ) void {
        std.debug.assert(completion == self.conn_completion);

        self.conn_socket = result catch |err| {
            self.err = err;
            return;
        };

        // set connection timestamp and timeout
        self.last_active = std.time.Instant.now() catch |err| {
            log.err("accept timestamp error: {any}", .{err});
            return;
        };
        self.loop.io.timeout(
            *Ctx,
            self,
            Ctx.timeoutCbk,
            self.timeout_completion,
            TimeoutCheck,
        );

        // receving incomming messages asynchronously
        self.loop.io.recv(
            *Ctx,
            self,
            Ctx.readCbk,
            self.conn_completion,
            self.conn_socket,
            self.read_buf,
        );
    }

    fn readCbk(self: *Ctx, completion: *Completion, result: RecvError!usize) void {
        std.debug.assert(completion == self.conn_completion);

        const size = result catch |err| {
            self.err = err;
            return;
        };

        if (size == 0) {
            // continue receving incomming messages asynchronously
            self.loop.io.recv(
                *Ctx,
                self,
                Ctx.readCbk,
                self.conn_completion,
                self.conn_socket,
                self.read_buf,
            );
            return;
        }

        // set connection timestamp
        self.last_active = std.time.Instant.now() catch |err| {
            log.err("read timestamp error: {any}", .{err});
            return;
        };

        // continue receving incomming messages asynchronously
        self.loop.io.recv(
            *Ctx,
            self,
            Ctx.readCbk,
            self.conn_completion,
            self.conn_socket,
            self.read_buf,
        );

        // read and execute input
        var input: []const u8 = self.read_buf[0..size];
        while (input.len > 0) {
            const parts = self.msg_buf.read(self.alloc(), input) catch |err| {
                if (err == error.MsgMultipart) {
                    return;
                } else {
                    log.err("msg read error: {any}", .{err});
                    return;
                }
            };
            input = parts.left;
            // execute
            self.do(parts.msg) catch |err| {
                if (err != error.Closed) {
                    log.err("do error: {any}", .{err});
                }
            };
        }
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
            log.err("timeout timestamp error: {any}", .{err});
            return;
        };

        if (now.since(self.last_active.?) > self.timeout) {
            // closing
            log.debug("conn timeout, closing...", .{});

            // NOTE: we should cancel the current read
            // but it seems that's just closing the connection is enough
            // (and cancel does not work on MacOS)

            // close current connection
            self.loop.io.close(
                *Ctx,
                self,
                Ctx.closeCbk,
                self.timeout_completion,
                self.conn_socket,
            );
            return;
        }

        // continue checking timeout
        self.loop.io.timeout(
            *Ctx,
            self,
            Ctx.timeoutCbk,
            self.timeout_completion,
            TimeoutCheck,
        );
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
                log.err("new session error: {any}", .{err});
                return;
            };
        }

        log.info("accepting new conn...", .{});

        // continue accepting incoming requests
        self.loop.io.accept(
            *Ctx,
            self,
            Ctx.acceptCbk,
            self.conn_completion,
            self.accept_socket,
        );
    }

    // shortcuts
    // ---------

    inline fn isClosed(self: *Ctx) bool {
        // last_active is first saved on acceptCbk
        return self.last_active == null;
    }

    // allocator of the current session
    inline fn alloc(self: *Ctx) std.mem.Allocator {
        return self.browser.session.alloc;
    }

    // JS env of the current session
    inline fn env(self: Ctx) jsruntime.Env {
        return self.browser.session.env;
    }

    // actions
    // -------

    fn do(self: *Ctx, cmd: []const u8) anyerror!void {

        // close cmd
        if (std.mem.eql(u8, cmd, "close")) {
            // close connection
            log.info("close cmd, closing conn...", .{});
            self.loop.io.close(
                *Ctx,
                self,
                Ctx.closeCbk,
                self.conn_completion,
                self.conn_socket,
            );
            return error.Closed;
        }

        if (self.sessionNew) self.sessionNew = false;

        const res = cdp.do(self.alloc(), cmd, self) catch |err| {

            // cdp end cmd
            if (err == error.DisposeBrowserContext) {
                // restart a new browser session
                std.log.scoped(.cdp).debug("end cmd, restarting a new session...", .{});
                try self.newSession();
                return;
            }

            return err;
        };

        // send result
        if (!std.mem.eql(u8, res, "")) {
            return sendAsync(self, res);
        }
    }

    fn newSession(self: *Ctx) !void {
        try self.browser.newSession(self.alloc(), self.loop);
        try self.browser.session.initInspector(
            self,
            Ctx.onInspectorResp,
            Ctx.onInspectorNotif,
        );
        self.sessionNew = true;
    }

    // inspector
    // ---------

    pub fn sendInspector(self: *Ctx, msg: []const u8) void {
        if (self.env().getInspector()) |inspector| {
            inspector.send(self.env(), msg);
        } else @panic("Inspector has not been set");
    }

    inline fn inspectorCtx(ctx_opaque: *anyopaque) *Ctx {
        const aligned = @as(*align(@alignOf(Ctx)) anyopaque, @alignCast(ctx_opaque));
        return @as(*Ctx, @ptrCast(aligned));
    }

    fn inspectorMsg(allocator: std.mem.Allocator, ctx: *Ctx, msg: []const u8) !void {
        // inject sessionID in cdp msg
        const tpl = "{s},\"sessionId\":\"{s}\"}}";
        const msg_open = msg[0 .. msg.len - 1]; // remove closing bracket
        const s = try std.fmt.allocPrint(
            allocator,
            tpl,
            .{ msg_open, cdp.ContextSessionID },
        );
        defer ctx.alloc().free(s);

        try sendSync(ctx, s);
    }

    pub fn onInspectorResp(ctx_opaque: *anyopaque, _: u32, msg: []const u8) void {
        if (std.log.defaultLogEnabled(.debug)) {
            // msg should be {"id":<id>,...
            const id_end = std.mem.indexOfScalar(u8, msg, ',') orelse unreachable;
            const id = msg[6..id_end];
            std.log.scoped(.cdp).debug("Res (inspector) > id {s}", .{id});
        }
        const ctx = inspectorCtx(ctx_opaque);
        inspectorMsg(ctx.alloc(), ctx, msg) catch unreachable;
    }

    pub fn onInspectorNotif(ctx_opaque: *anyopaque, msg: []const u8) void {
        if (std.log.defaultLogEnabled(.debug)) {
            // msg should be {"method":<method>,...
            const method_end = std.mem.indexOfScalar(u8, msg, ',') orelse unreachable;
            const method = msg[10..method_end];
            std.log.scoped(.cdp).debug("Event (inspector) > method {s}", .{method});
        }
        const ctx = inspectorCtx(ctx_opaque);
        inspectorMsg(ctx.alloc(), ctx, msg) catch unreachable;
    }
};

// I/O Send
// --------

// NOTE: to allow concurrent send we create each time a dedicated context
// (with its own completion), allocated on the heap.
// After the send (on the sendCbk) the dedicated context will be destroy
// and the msg slice will be free.
const Send = struct {
    ctx: *Ctx,
    msg: []const u8,
    completion: Completion = undefined,

    fn init(ctx: *Ctx, msg: []const u8) !*Send {
        const sd = try ctx.alloc().create(Send);
        sd.* = .{ .ctx = ctx, .msg = msg };
        return sd;
    }

    fn deinit(self: *Send) void {
        self.ctx.alloc().free(self.msg);
        self.ctx.alloc().destroy(self);
    }

    fn asyncCbk(self: *Send, _: *Completion, result: SendError!usize) void {
        _ = result catch |err| {
            self.ctx.err = err;
            return;
        };
        self.deinit();
    }
};

pub fn sendAsync(ctx: *Ctx, msg: []const u8) !void {
    const sd = try Send.init(ctx, msg);
    ctx.loop.io.send(*Send, sd, Send.asyncCbk, &sd.completion, ctx.conn_socket, msg);
}

pub fn sendSync(ctx: *Ctx, msg: []const u8) !void {
    _ = try std.posix.write(ctx.conn_socket, msg);
}

// Listen
// ------

pub fn listen(
    alloc: std.mem.Allocator,
    loop: *jsruntime.Loop,
    server_socket: std.posix.socket_t,
    timeout: u64,
) anyerror!void {

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // browser
    var browser: Browser = undefined;
    try Browser.init(&browser, alloc, loop, vm);
    defer browser.deinit();

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
        .browser = &browser,
        .sessionNew = true,
        .read_buf = &read_buf,
        .msg_buf = &msg_buf,
        .accept_socket = server_socket,
        .timeout = timeout,
        .conn_completion = &conn_completion,
        .timeout_completion = &timeout_completion,
    };
    try browser.session.initInspector(
        &ctx,
        Ctx.onInspectorResp,
        Ctx.onInspectorNotif,
    );

    // accepting connection asynchronously on internal server
    log.info("accepting new conn...", .{});
    loop.io.accept(*Ctx, &ctx, Ctx.acceptCbk, ctx.conn_completion, ctx.accept_socket);

    // infinite loop on I/O events, either:
    // - cmd from incoming connection on server socket
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.tick();
        if (loop.cbk_error) {
            log.err("JS error", .{});
            // if (try try_catch.exception(alloc, js_env.*)) |msg| {
            //     std.debug.print("\n\rUncaught {s}\n\r", .{msg});
            //     alloc.free(msg);
            // }
            // loop.cbk_error = false;
        }
        if (ctx.err) |err| {
            if (err != error.NoError) log.err("Server error: {any}", .{err});
            break;
        }
    }
}
