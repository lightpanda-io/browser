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
            .inbox = inbox,
            .browser = &d.browser, // browser will still be undefined at this point, but its address is known
            .scope = @field(log.Scope, @tagName(tag)), // The tag names line up with the log scopes of the same name.
        },
    };
}

// server loop. Whether losing the link ends the worker.
pub fn connectionScoped(self: *const Driver) bool {
    return switch (self.impl) {
        .cdp => true, // always true for CDP; CDP is WebSocket only
        .bidi => |bidi| bidi.mode == .bidi_only, // depends if this is BiDi-only WebDriver session
    };
}

// server loop. The loop shuts the link's read side itself (Server.Worker
// owns that pointer); this only stops the JS.
pub fn shutdown(self: *const Driver) void {
    self.browser.env.terminate();
}

// server loop. Something was pushed to the inbox; wake the worker from its poll.
pub fn wakeup(self: *const Driver) void {
    self.browser.http_client.handles.wakeup() catch |err| {
        log.err(self.scope, "wakeup", .{ .err = err });
    };
}

// Worker thread. Note that (for bidi at least) the link can come and go
fn link(self: *const Driver) ?*Link {
    return switch (self.impl) {
        .cdp => |cdp| &cdp.link,
        .bidi => |bidi| bidi.link,
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
    const l = self.link() orelse return;
    l.sendPong(body) catch |err| {
        log.warn(self.scope, "pong", .{ .err = err });
    };
}

// Worker Thread. The worker is being given a link
pub fn onLink(self: *const Driver, l: *Link) void {
    switch (self.impl) {
        .bidi => |bidi| bidi.adoptLink(l),
        .cdp => {
            // a CDP worker is born with its link and never offered another
            log.err(self.scope, "unexpected link", .{});
            l.destroy();
        },
    }
}

// Worker Thread. The websocket is closing. Should we kill the worker? That's
// up to the implementation (hint: for CDP, it's always "yes" and for WebDriver
// it's "yes" for a BiDi-only session)
pub fn onClose(self: *const Driver) bool {
    if (self.link()) |l| {
        l.send(&WS.CLOSE_NORMAL) catch |err| {
            log.warn(self.scope, "close reply", .{ .err = err });
        };
    }
    return self.onDisconnect(null);
}

// Worker Thread. Unlike onClose, this is an unconditional termination.
// (Currently only comes from WebDriver endpoints (HTTP or WS))
pub fn onQuit(self: *const Driver) void {
    if (self.link()) |l| {
        l.send(&WS.CLOSE_NORMAL) catch |err| {
            log.warn(self.scope, "quit close", .{ .err = err });
        };
    }
    log.info(self.scope, "session ended", .{});
}

// Worker Thread. Returns true when the worker is done.
pub fn onDisconnect(self: *const Driver, err: ?anyerror) bool {
    if (err) |e| {
        if (WS.errorReply(e)) |close_frame| {
            if (self.link()) |l| {
                l.send(close_frame) catch {};
            }
        }
    }
    log.info(self.scope, "disconnect", .{ .err = err });
    return switch (self.impl) {
        .cdp => true,
        .bidi => |bidi| bidi.onLinkGone(),
    };
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
        // Our own requestTerminate from Server.dropWebSocket: the peer is gone or
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
        if (self.link()) |l| {
            l.send(&WS.CLOSE_GOING_AWAY) catch |err| {
                log.warn(self.scope, "terminate close", .{ .err = err });
            };
        }
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
