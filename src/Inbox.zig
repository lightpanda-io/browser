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

// Thread-safe FIFO of Messages. Producer pushes from one thread,
// consumer pops from another. No wake mechanism is bundled — callers
// arrange that themselves (e.g. curl_multi_wakeup on the consumer's
// curl multi handle).
//
// Backed by a DoublyLinkedList so that pop is O(1) and the
// allowlist-during-sync-wait drain can cherry-pick messages out of
// the middle in O(1) given a node pointer.

const std = @import("std");
const lp = @import("lightpanda");

const CDP = @import("cdp/CDP.zig");

const ArenaPool = @import("ArenaPool.zig");

const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const Inbox = @This();

mutex: std.Io.Mutex = .init,
queue: DoublyLinkedList = .{},

// One-way latch, set by the worker's drainInbox the first time it
// observes a .disconnect (or .close) and never cleared. Ensures that, on
// multiple drains, the terminated state is preserved / communicated. This is
// specifically meant to handle the case where a disconnect is captured during
// a syncRequest and we want the following non-nested tick to pick it up again.
terminated: bool = false,

pub fn deinit(self: *Inbox, arena_pool: *ArenaPool) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    while (self.queue.popFirst()) |node| {
        const msg: *Message = @fieldParentPtr("node", node);
        msg.deinit(arena_pool);
    }
}

pub fn push(self: *Inbox, arena: Allocator, payload: Message.Payload) void {
    const msg = arena.create(Message) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };

    msg.* = .{ .payload = payload, .arena = arena };
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    self.queue.append(&msg.node);
}

pub fn pop(self: *Inbox) ?*Message {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    const node = self.queue.popFirst() orelse return null;
    return @fieldParentPtr("node", node);
}

// Peek for a message matching `predicate` without removing it. Used by
// syncRequest to notice a queued teardown command (which sync_wait can't
// safely dispatch mid-parse) so it can abort the blocking fetch instead
// of stalling for the full per-request timeout.
pub fn contains(self: *Inbox, predicate: *const fn (*Message) bool) bool {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    var it = self.queue.first;
    while (it) |node| : (it = node.next) {
        const msg: *Message = @fieldParentPtr("node", node);
        if (predicate(msg)) return true;
    }
    return false;
}

// Cherry-pick the first message for which `predicate(msg)` returns
// true, removing it from the queue. Walks the queue in FIFO order;
// non-matching messages stay in place. Used to dispatch only the
// safe subset of messages during sync-wait paths (the allowlist),
// while leaving unsafe ones to be drained at the next safe point.
pub fn popIf(self: *Inbox, predicate: *const fn (*Message) bool) ?*Message {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    var it = self.queue.first;
    while (it) |node| : (it = node.next) {
        const msg: *Message = @fieldParentPtr("node", node);
        if (predicate(msg)) {
            self.queue.remove(node);
            return msg;
        }
    }
    return null;
}

pub const Message = struct {
    arena: Allocator,
    payload: Payload,
    node: DoublyLinkedList.Node = .{},

    pub const Payload = union(enum) {
        // A CDP text/binary frame, parsed on the Network thread. `raw`
        // is the original JSON bytes (owned). `arena` holds any
        // auxiliary allocations from parseFromSliceLeaky (typically
        // empty for unescaped messages, but slices in `input` may
        // reference it). `input` is the parsed view; its string
        // slices reference `raw` or `arena`. Both must outlive the
        // consumer's use of `input`.
        cdp: Cdp,

        // WS ping frame body (≤125 bytes per spec). Consumer is
        // expected to echo via pong on its thread.
        ping: []u8,

        // Peer-initiated close frame. Consumer is expected to send a
        // close reply and tear the connection down. The peer's close
        // body is dropped — historically we always reply CLOSE_NORMAL
        // (status 1000) regardless of what the peer sent.
        close: void,

        // No allocation; conveys "no more messages will arrive on
        // this inbox" plus an optional reason. The Network thread
        // pushes this on peer EOF, fatal WS framing error, or
        // (now) JSON parse failure.
        disconnect: ?anyerror,
    };

    pub const Cdp = struct {
        raw: []u8,
        input: CDP.InputMessage,
    };

    pub fn deinit(self: *const Message, pool: *ArenaPool) void {
        pool.release(self.arena);
    }
};

const testing = @import("testing.zig");
test "Inbox: push then pop returns FIFO order" {
    const arena_pool = &testing.test_app.arena_pool;

    var inbox = Inbox{};
    defer inbox.deinit(&testing.test_app.arena_pool);

    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "first") });
    }

    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "second") });
    }

    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .disconnect = null });
    }

    {
        const m = inbox.pop().?;
        defer m.deinit(arena_pool);
        try testing.expectEqual("first", m.payload.ping);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit(arena_pool);
        try testing.expectEqual("second", m.payload.ping);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit(arena_pool);
        try testing.expectEqual(@as(?anyerror, null), m.payload.disconnect);
    }
    try testing.expect(inbox.pop() == null);
}

test "Inbox: deinit frees remaining items" {
    const arena_pool = &testing.test_app.arena_pool;

    var inbox = Inbox{};
    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "leftover") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .disconnect = error.PeerClosed });
    }

    inbox.deinit(&testing.test_app.arena_pool);
    // Memory leaks would be caught by the test runner.
}

fn testAlwaysTrue(_: *Message) bool {
    return true;
}

fn testAlwaysFalse(_: *Message) bool {
    return false;
}

fn testIsPing(msg: *Message) bool {
    return msg.payload == .ping;
}

test "Inbox: popIf on empty queue returns null" {
    var inbox = Inbox{};
    defer inbox.deinit(&testing.test_app.arena_pool);
    try testing.expect(inbox.popIf(testAlwaysTrue) == null);
}

test "Inbox: popIf with no match leaves queue intact" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit(arena_pool);

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "first") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "second") });
    }

    try testing.expect(inbox.popIf(testAlwaysFalse) == null);

    // Original FIFO order preserved.
    {
        const m = inbox.pop().?;
        defer m.deinit(arena_pool);
        try testing.expectEqual("first", m.payload.ping);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit(arena_pool);
        try testing.expectEqual("second", m.payload.ping);
    }
    try testing.expect(inbox.pop() == null);
}

test "Inbox: popIf with always-true predicate behaves like pop" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit(arena_pool);

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "a") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "b") });
    }

    {
        const m = inbox.popIf(testAlwaysTrue).?;
        defer m.deinit(arena_pool);
        try testing.expectEqual("a", m.payload.ping);
    }
    {
        const m = inbox.popIf(testAlwaysTrue).?;
        defer m.deinit(arena_pool);
        try testing.expectEqual("b", m.payload.ping);
    }
    try testing.expect(inbox.popIf(testAlwaysTrue) == null);
}

test "Inbox: popIf cherry-picks middle, preserves order of remainder" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit(arena_pool);

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .disconnect = null });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "middle") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .disconnect = error.PeerClosed });
    }

    // testIsPing skips the disconnect at the head and picks the middle.
    {
        const m = inbox.popIf(testIsPing).?;
        defer m.deinit(arena_pool);
        try testing.expectEqual("middle", m.payload.ping);
    }

    // Remaining two disconnects pop in original order.
    {
        const m = inbox.pop().?;
        defer m.deinit(arena_pool);
        try testing.expect(m.payload.disconnect == null);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit(arena_pool);
        try testing.expect(m.payload.disconnect.? == error.PeerClosed);
    }
    try testing.expect(inbox.pop() == null);
}

test "Inbox: popIf picks first match in FIFO order" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit(arena_pool);

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "first") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .disconnect = null });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "second") });
    }

    const m = inbox.popIf(testIsPing).?;
    defer m.deinit(arena_pool);
    try testing.expectEqual("first", m.payload.ping);
}
