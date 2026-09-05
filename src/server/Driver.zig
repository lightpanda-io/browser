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

const lp = @import("lightpanda");

const Inbox = @import("../Inbox.zig");
const Browser = @import("../browser/Browser.zig");
const Session = @import("../browser/Session.zig");

const WS = @import("WS.zig");
const Link = @import("Link.zig");

const CDP = @import("cdp/CDP.zig");
const BiDi = @import("bidi/BiDi.zig");

const log = lp.log;

// Parts of the driver are owned by the server loop, parts are owned by
// the worker thread. The run loop reads messages and pushes to the inbox,
// the worker mostly just writes to the socket.
const Driver = @This();

// Doubles as the metrics label
pub const Protocol = enum { cdp, bidi };

pub const Impl = union(Protocol) {
    cdp: *CDP,
    bidi: *BiDi,
};

impl: Impl,

// every implementation has this
conn: *Link,
browser: *Browser,

// The worker's mailbox, owned by the loop's connection slot (it outlives
// the link). The loop pushes, the worker's HttpClient drains through us.
inbox: *Inbox,

// The protocol's log scope, so shared code still logs as .cdp / .bidi.
scope: log.Scope,

pub fn init(impl: Impl, inbox: *Inbox) Driver {
    return switch (impl) {
        inline else => |d, tag| .{
            .impl = impl,
            .conn = &d.conn,
            .browser = &d.browser,
            .inbox = inbox,
            .scope = @field(log.Scope, @tagName(tag)), // The tag names line up with the log scopes of the same name.
        },
    };
}

// server loop. The socket is readable, drain up to budget bytes
pub fn onReadable(self: *const Driver, budget: usize) anyerror!bool {
    const read = try self.conn.readAvailable(budget);
    if (read.pushed) {
        self.wakeup();
    }
    return read.keep;
}

// server loop. Called when it drops the link unsolicited (peer EOF, ...)
pub fn onLinkDisconnect(self: *const Driver, err: ?anyerror) void {
    const arena = self.browser.arena_pool.acquire(.tiny, "driver disconnect") catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM"),
    };
    // order matters, this ensures that the disconnect message is in the inbox
    // when tick() discovers the terminatePending flag is set.
    self.inbox.push(arena, .{ .disconnect = err });
    self.browser.env.requestTerminate();
    self.wakeup();
}

// server loop. We used to send a nice WS close frame here but (a) it isn't strictly
// required and (b) we'd have to protect against an interleaved write from
// the worker thread.
pub fn shutdown(self: *const Driver) void {
    self.browser.env.terminate();
    self.conn.shutdown();
}

// a server-processed call (onReadable, onLinkDisconnect) wants to signal the
// worker that there's data in its inbox waiting to be processed.
fn wakeup(self: *const Driver) void {
    self.browser.http_client.handles.wakeup() catch |err| {
        log.err(self.scope, "wakeup", .{ .err = err });
    };
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

// Worker thread.
pub fn run(self: *const Driver) void {
    self.attach(); // make HttpClient aware of our inbox
    defer self.detach(); // make HttpClient forget our inbox
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

// Worker thread. Tell the http_client about us (so it can monitor our inbox)
pub fn attach(self: *const Driver) void {
    self.browser.http_client.driver = self.*;
}

// Worker thread.
pub fn detach(self: *const Driver) void {
    self.browser.http_client.driver = null;
}

// One iteration of the worker loop. Returns false to disconnect.
fn tick(self: *const Driver) !bool {
    if (self.browser.env.terminatePending()) {
        // Our own requestTerminate from onLinkDisconnect: the peer is gone or
        // sent garbage. Report it with its own close code, nothing to warn
        // about. Pops close/disconnect only: nothing else may be dispatched
        // in a shutting-down state.
        self.browser.http_client.drainTerminal() catch |err| switch (err) {
            error.ClientDisconnected => return false,
        };

        // Anything else means someone decided this browser must die (e.g.
        // shutdown, or the heap limit was reached).
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
