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
const Transfer = @import("HttpClient.zig").Transfer;
const Allocator = std.mem.Allocator;

const SingleFlight = @This();

allocator: Allocator,
pending: std.StringHashMapUnmanaged(std.ArrayList(*Transfer)) = .empty,

pub fn deinit(self: *SingleFlight) void {
    var it = self.pending.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(self.allocator);
    }
    self.pending.deinit(self.allocator);
}

pub const EnterResult = enum { initial, queued };

pub fn enter(self: *SingleFlight, key: []const u8, transfer: *Transfer, reason: Transfer.ParkedBy) !EnterResult {
    const gop = try self.pending.getOrPut(self.allocator, key);
    var waiting = gop.value_ptr;

    if (gop.found_existing) {
        try waiting.append(self.allocator, transfer);
        transfer.park(reason);
        return .queued;
    }

    waiting.* = .empty;
    try waiting.append(self.allocator, transfer);
    errdefer waiting.deinit(self.allocator);
    transfer.park(reason);

    return .initial;
}

pub fn abort(self: *SingleFlight, key: []const u8) void {
    var entry = self.pending.fetchRemove(key) orelse return;
    entry.value.deinit(self.allocator);
}

pub fn remove(self: *SingleFlight, transfer: *Transfer) void {
    var it = self.pending.valueIterator();
    while (it.next()) |waiting| {
        for (waiting.items, 0..) |t, i| {
            if (t == transfer) {
                _ = waiting.swapRemove(i);
                return;
            }
        }
    }
}

pub fn take(self: *SingleFlight, key: []const u8) ?std.ArrayList(*Transfer) {
    const entry = self.pending.fetchRemove(key) orelse return null;
    return entry.value;
}

pub fn discard(self: *SingleFlight, key: []const u8) void {
    var entry = self.pending.fetchRemove(key) orelse return;
    entry.value.deinit(self.allocator);
}

pub fn count(self: *SingleFlight) u32 {
    return self.pending.count();
}

const testing = @import("../testing.zig");
const ArenaPool = @import("../ArenaPool.zig");
const HttpClient = @import("HttpClient.zig");

fn makeTestTransfer(arena: Allocator, client: *HttpClient, id: u32) !*Transfer {
    const t = try arena.create(Transfer);
    t.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .shutdown_callback = HttpClient.noopShutdown,
        },
        .client = client,
        .id = id,
        .start_time = 0,
    };
    return t;
}

test "SingleFlight: enter returns initial for the first waiter" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    // Only transfers.remove/pending_queue.remove/etc. touched by deinit
    // matter here; a minimal zeroed client is enough since these tests
    // never call transfer.deinit(), only single_flight directly.
    client = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    const t2 = try makeTestTransfer(arena, &client, 2);
    const t3 = try makeTestTransfer(arena, &client, 3);

    try testing.expectEqual(.initial, try sf.enter("key", t1, .robots));
    try testing.expectEqual(.queued, try sf.enter("key", t2, .robots));
    try testing.expectEqual(.queued, try sf.enter("key", t3, .robots));

    try testing.expectEqual(1, sf.count());
    try testing.expectEqual(Transfer.State{ .parked = .robots }, t1.state);
    try testing.expectEqual(Transfer.State{ .parked = .robots }, t2.state);
    try testing.expectEqual(Transfer.State{ .parked = .robots }, t3.state);
}

test "SingleFlight: different keys get independent entries" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    const t2 = try makeTestTransfer(arena, &client, 2);

    try testing.expectEqual(.initial, try sf.enter("key-a", t1, .robots));
    try testing.expectEqual(.initial, try sf.enter("key-b", t2, .robots));

    try testing.expectEqual(2, sf.count());
}

test "SingleFlight: take removes and returns the waiter list" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    const t2 = try makeTestTransfer(arena, &client, 2);

    _ = try sf.enter("key", t1, .robots);
    _ = try sf.enter("key", t2, .robots);

    var waiting = sf.take("key") orelse return error.TestUnexpectedResult;
    defer waiting.deinit(testing.allocator);

    try testing.expectEqual(2, waiting.items.len);
    try testing.expect(waiting.items[0] == t1);
    try testing.expect(waiting.items[1] == t2);

    // Entry is gone: a second take on the same key finds nothing.
    try testing.expectEqual(null, sf.take("key"));
    try testing.expectEqual(0, sf.count());
}

test "SingleFlight: take on an unknown key returns null" {
    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    try testing.expectEqual(null, sf.take("missing"));
}

test "SingleFlight: abort drops the pending entry without resolving waiters" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    _ = try sf.enter("key", t1, .robots);

    sf.abort("key");

    try testing.expectEqual(0, sf.count());
    try testing.expectEqual(null, sf.take("key"));
}

test "SingleFlight: discard is equivalent to abort for the shutdown path" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    const t2 = try makeTestTransfer(arena, &client, 2);
    _ = try sf.enter("key", t1, .robots);
    _ = try sf.enter("key", t2, .robots);

    sf.discard("key");

    try testing.expectEqual(0, sf.count());
}

test "SingleFlight: remove unlinks a single waiter from its key's list" {
    // Regression-style, mirrors "aborting a robots-parked transfer unlinks
    // it from the gate" but exercised directly against SingleFlight rather
    // than through RobotsGate.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    const t2 = try makeTestTransfer(arena, &client, 2);
    const t3 = try makeTestTransfer(arena, &client, 3);

    _ = try sf.enter("key", t1, .robots);
    _ = try sf.enter("key", t2, .robots);
    _ = try sf.enter("key", t3, .robots);

    sf.remove(t2);

    var waiting = sf.take("key") orelse return error.TestUnexpectedResult;
    defer waiting.deinit(testing.allocator);

    try testing.expectEqual(2, waiting.items.len);
    try testing.expect(waiting.items[0] == t1);
    try testing.expect(waiting.items[1] == t3);
}

test "SingleFlight: remove on a transfer not in any list is a no-op" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    const stray = try makeTestTransfer(arena, &client, 2);

    _ = try sf.enter("key", t1, .robots);

    // stray was never entered anywhere; remove must not touch t1's entry.
    sf.remove(stray);

    try testing.expectEqual(1, sf.count());
    var waiting = sf.take("key") orelse return error.TestUnexpectedResult;
    defer waiting.deinit(testing.allocator);
    try testing.expectEqual(1, waiting.items.len);
}

test "SingleFlight: removing every waiter for a key leaves an empty (but present) list" {
    // remove() only swapRemoves from the waiter list; it does not delete the
    // map entry even if the list becomes empty. take()/abort()/discard() are
    // the only ways the entry itself disappears. This documents that
    // asymmetry so a future change doesn't accidentally break RobotsGate's
    // "entry stays, in-flight fetch still owns it" invariant.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: HttpClient = undefined;
    client.transfers = .empty;
    client.intercepted = 0;

    var sf = SingleFlight{ .allocator = testing.allocator };
    defer sf.deinit();

    const arena = try pool.acquire(.small, "test");
    defer pool.release(arena);

    const t1 = try makeTestTransfer(arena, &client, 1);
    _ = try sf.enter("key", t1, .robots);

    sf.remove(t1);

    try testing.expectEqual(1, sf.count());
    var waiting = sf.take("key") orelse return error.TestUnexpectedResult;
    defer waiting.deinit(testing.allocator);
    try testing.expectEqual(0, waiting.items.len);
}
