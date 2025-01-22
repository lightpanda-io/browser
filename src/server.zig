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
const builtin = @import("builtin");

const Stream = @import("handler.zig").Stream;

const jsruntime = @import("jsruntime");
const Completion = jsruntime.IO.Completion;
const AcceptError = jsruntime.IO.AcceptError;
const RecvError = jsruntime.IO.RecvError;
const SendError = jsruntime.IO.SendError;
const CloseError = jsruntime.IO.CloseError;
const CancelError = jsruntime.IO.CancelError;
const TimeoutError = jsruntime.IO.TimeoutError;

const MsgBuffer = @import("msg.zig").Buffer;
const MaxSize = @import("msg.zig").MaxSize;
const Browser = @import("browser/browser.zig").Browser;
const cdp = @import("cdp/cdp.zig");

const NoError = error{NoError};
const IOError = AcceptError || RecvError || SendError || CloseError || TimeoutError || CancelError;
const Error = IOError || std.fmt.ParseIntError || cdp.Error || NoError;

const TimeoutCheck = std.time.ns_per_ms * 100;

const log = std.log.scoped(.server);
const isLinux = builtin.target.os.tag == .linux;

// I/O Main
// --------

const BufReadSize = 1024; // 1KB
const MaxStdOutSize = 512; // ensure debug msg are not too long

pub const Ctx = struct {
    loop: *jsruntime.Loop,
    stream: ?*Stream,

    // internal fields
    accept_socket: std.posix.socket_t,
    conn_socket: std.posix.socket_t = undefined,
    read_buf: []u8, // only for read operations
    msg_buf: *MsgBuffer,
    err: ?Error = null,

    // I/O fields
    accept_completion: *Completion,
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
        std.debug.assert(completion == self.acceptCompletion());

        self.conn_socket = result catch |err| {
            log.err("accept error: {any}", .{err});
            self.err = err;
            return;
        };
        log.info("client connected", .{});

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
            if (self.isClosed() and err == error.FileDescriptorInvalid) {
                log.debug("read has been canceled", .{});
                return;
            }
            log.err("read error: {any}", .{err});
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
            const parts = self.msg_buf.read(input) catch |err| {
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
                    log.debug("last msg: {s}", .{parts.msg});
                }
            };
        }
    }

    fn timeoutCbk(self: *Ctx, completion: *Completion, result: TimeoutError!void) void {
        std.debug.assert(completion == self.timeout_completion);

        _ = result catch |err| {
            log.err("timeout error: {any}", .{err});
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
            // close current connection
            log.debug("conn timeout, closing...", .{});
            self.close();
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

    inline fn acceptCompletion(self: *Ctx) *Completion {
        // NOTE: the logical completion to use here is the accept_completion
        // as the pipe_connection can be used simulteanously by a recv I/O operation.
        // But on MacOS (kqueue) the recv I/O operation on a closed socket leads to a panic
        // so we use the pipe_connection to avoid this problem
        if (isLinux) return self.accept_completion;
        return self.conn_completion;
    }

    // actions
    // -------

    fn do(self: *Ctx, cmd: []const u8) anyerror!void {

        // close cmd
        if (std.mem.eql(u8, cmd, "close")) {
            // close connection
            log.info("close cmd, closing conn...", .{});
            self.close();
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
            return self.send(res);
        }
    }

    pub fn send(self: *Ctx, msg: []const u8) !void {
        if (self.stream) |stream| {
            // if we have a stream connection, just write on it
            defer self.alloc().free(msg);
            try stream.send(msg);
        } else {
            // otherwise write asynchronously on the socket connection
            return sendAsync(self, msg);
        }
    }

    fn close(self: *Ctx) void {

        // conn is closed
        self.last_active = null;
        std.posix.close(self.conn_socket);
        log.debug("connection closed", .{});

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
            self.acceptCompletion(),
            self.accept_socket,
        );
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
            .{ msg_open, ctx.state.sessionID orelse cdp.ContextSessionID },
        );

        try ctx.send(s);
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
            log.err("send error: {any}", .{err});
            self.ctx.err = err;
        };
        self.deinit();
    }
};

pub fn sendAsync(ctx: *Ctx, msg: []const u8) !void {
    const sd = try Send.init(ctx, msg);
    ctx.loop.io.send(*Send, sd, Send.asyncCbk, &sd.completion, ctx.conn_socket, sd.msg);
}

// Listener and handler
// --------------------

pub fn handle(
    alloc: std.mem.Allocator,
    loop: *jsruntime.Loop,
    server_socket: std.posix.socket_t,
    stream: ?*Stream,
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
    var buf: [MaxSize]u8 = undefined;
    var msg_buf = MsgBuffer{ .buf = &buf };

    // create I/O completions
    var accept_completion: Completion = undefined;
    var conn_completion: Completion = undefined;
    var timeout_completion: Completion = undefined;

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var ctx = Ctx{
        .loop = loop,
        .stream = stream,
        .browser = &browser,
        .sessionNew = true,
        .read_buf = &read_buf,
        .msg_buf = &msg_buf,
        .accept_socket = server_socket,
        .timeout = timeout,
        .accept_completion = &accept_completion,
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
    loop.io.accept(*Ctx, &ctx, Ctx.acceptCbk, ctx.acceptCompletion(), ctx.accept_socket);

    // infinite loop on I/O events, either:
    // - cmd from incoming connection on server socket
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.run_for_ns(10 * std.time.ns_per_ms);
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

fn setSockOpt(fd: std.posix.socket_t, level: i32, option: u32, value: c_int) !void {
    try std.posix.setsockopt(fd, level, option, &std.mem.toBytes(value));
}

fn isUnixSocket(addr: std.net.Address) bool {
    return addr.any.family == std.posix.AF.UNIX;
}

pub fn listen(address: std.net.Address) !std.posix.socket_t {
    const isunixsock = isUnixSocket(address);

    // create socket
    const flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
    const proto = if (isunixsock) @as(u32, 0) else std.posix.IPPROTO.TCP;
    const sockfd = try std.posix.socket(address.any.family, flags, proto);
    errdefer std.posix.close(sockfd);

    // socket options
    //
    // REUSEPORT can't be set on unix socket anymore.
    // see https://github.com/torvalds/linux/commit/5b0af621c3f6ef9261cf6067812f2fd9943acb4b
    if (@hasDecl(std.posix.SO, "REUSEPORT") and !isunixsock) {
        try setSockOpt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, 1);
    }
    try setSockOpt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, 1);
    if (!isUnixSocket(address)) {
        if (builtin.target.os.tag == .linux) { // posix.TCP not available on MacOS
            // WARNING: disable Nagle's alogrithm to avoid latency issues
            try setSockOpt(sockfd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, 1);
        }
    }

    // bind & listen
    var socklen = address.getOsSockLen();
    try std.posix.bind(sockfd, &address.any, socklen);
    const kernel_backlog = 1; // default value is 128. Here we just want 1 connection
    try std.posix.listen(sockfd, kernel_backlog);
    var listen_address: std.net.Address = undefined;
    try std.posix.getsockname(sockfd, &listen_address.any, &socklen);

    return sockfd;
}
