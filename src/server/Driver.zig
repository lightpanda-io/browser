// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const WS = @import("../network/WS.zig");
const Inbox = @import("../Inbox.zig");

const CDP = @import("cdp/CDP.zig");
const Server = @import("Server.zig");
const BiDi = @import("bidi/BiDi.zig");
const Connection = @import("Connection.zig");
const Browser = @import("../browser/Browser.zig");
const Session = @import("../browser/Session.zig");

const log = lp.log;

// Parts of the driver are owned by the server run loop, parts are owned by
// the worker thread. The run loop reads messages and pushes to the inbox,
// the worker mostly just writes to the socket.
//
// What every protocol has - a connection, a browser, a link to the network
// thread - lives here rather than behind `impl`, so the shared paths are plain
// field access. Only what genuinely differs switches on `impl`.
const Driver = @This();

pub const Impl = union(enum) {
    cdp: *CDP,
    bidi: *BiDi,
};

impl: Impl,
conn: *Connection,
browser: *Browser,
link: *Server.Link,

// The protocol's log scope, so shared code still logs as .cdp / .bidi.
scope: log.Scope,

// Called from CDP.init / BiDi.init, where conn, link and browser are all
// still undefined: we only take their addresses, which the impl's own
// allocation already fixed.
pub fn init(impl: Impl) Driver {
    return switch (impl) {
        // The tag names line up with the log scopes of the same name.
        inline else => |d, tag| .{
            .impl = impl,
            .conn = &d.conn,
            .link = &d.link,
            .browser = &d.browser,
            .scope = @field(log.Scope, @tagName(tag)),
        },
    };
}

// Server run loop. Received data, driver returns false to signal it should
// disconnect.
pub fn onData(self: *const Driver, data: []const u8) anyerror!bool {
    return self.conn.feed(data);
}

// Server run loop. Called when it drops the link unsolicited (peer EOF, ...)
pub fn onLinkDisconnect(self: *const Driver, err: ?anyerror) void {
    self.browser.env.requestTerminate();
    const arena = self.browser.arena_pool.acquire(.tiny, "driver disconnect") catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM"),
    };
    self.browser.http_client.inbox.push(arena, .{ .disconnect = err });
}

// Worker thread. We're processing messages from the inbox.
pub fn onMessage(self: *const Driver, msg: *Inbox.Message) anyerror!void {
    return switch (self.impl) {
        .cdp => |cdp| cdp.onMessage(&msg.payload.cdp),
        .bidi => |bidi| bidi.onMessage(msg.payload.bidi),
    };
}

// Worker Thread. We're processing messages from the inbox.
pub fn onPing(self: *const Driver, body: []const u8) void {
    self.conn.sendPong(body) catch |err| {
        log.warn(self.scope, "pong", .{ .err = err });
    };
}

// Worker Thread. We're processing messages from the inbox.
pub fn onClose(self: *const Driver) void {
    self.conn.send(&WS.CLOSE_NORMAL) catch |err| {
        log.warn(self.scope, "close reply", .{ .err = err });
    };
    self.onDisconnect(null);
}

// Worker Thread. We're processing messages from the inbox.
pub fn onDisconnect(self: *const Driver, err: ?anyerror) void {
    if (err) |e| {
        if (WS.errorReply(e)) |close_frame| {
            self.conn.send(close_frame) catch {};
        }
    }
    log.info(self.scope, "disconnect", .{ .err = err });
}

// Worker thread. Once the websocket connection is established, the server
// calls this (from the worker thread) and it becomes the driving loop.
pub fn run(self: *const Driver) void {
    while (true) {
        const alive = self.tick() catch |err| {
            log.err(self.scope, "tick", .{ .err = err });
            return;
        };
        if (alive == false) {
            return;
        }
    }
}

// One iteration of the worker loop. Returns false to disconnect.
fn tick(self: *const Driver) !bool {
    if (self.browser.env.terminatePending()) {
        // terminatePending means someone decided this browser must die
        // (e.g. the heap limit was reached).
        log.warn(self.scope, "closing connection", .{ .reason = "pending terminate" });
        // The worker thread is the sole writer of this socket, so sending
        // the close frame here can't interleave with another write.
        self.conn.send(&WS.CLOSE_GOING_AWAY) catch |err| {
            log.warn(self.scope, "terminate close", .{ .err = err });
        };
        return false;
    }

    // Liveness is enforced by TCP keepalive configured in
    // Server.configureSocket; the wakeup lets V8 run or terminate.
    const wait_ms: u32 = 1000; // 1s

    if (self.pageWait()) |wait| {
        var runner = wait.session.runner(.{});
        runner.waitForFrameCDP(wait.frame_id, wait_ms, .done) catch |err| switch (err) {
            error.ClientDisconnected => return false,
            else => return err,
        };
        return true;
    }

    // No active page yet (or a teardown is in flight). Fall back to ticking
    // the http client directly so commands still get dispatched.
    _ = self.browser.http_client.tick(wait_ms) catch |err| switch (err) {
        error.ClientDisconnected => return false,
        else => {
            log.err(self.scope, "http tick", .{ .err = err });
            return false;
        },
    };
    return true;
}

const PageWait = struct {
    session: *Session,
    frame_id: u32,
};

// The page this connection's tick should wait on, null when there isn't one.
fn pageWait(self: *const Driver) ?PageWait {
    switch (self.impl) {
        .cdp => |cdp| {
            const bc = &(cdp.browser_context orelse return null);
            const page = bc.page_handle orelse return null;
            return .{ .session = bc.session, .frame_id = page.frame_id };
        },
        .bidi => |bidi| {
            const context = bidi.browsing_context orelse return null;
            return .{ .session = bidi.user_context.session, .frame_id = context.frame_id };
        },
    }
}

// signal handler thread
pub fn shutdown(self: *const Driver) void {
    if (self.conn.state == .live) {
        self.browser.env.terminate();
        // We use to send a nice WS close frame here but (a) it isn't
        // strictly required and (b) we'd have to protect against an interleaved
        // write from the worker thread.
    }
    self.conn.shutdown();
}
