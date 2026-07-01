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

const Transfer = @import("../browser/HttpClient.zig").Transfer;

const Coalescer = @This();

allocator: std.mem.Allocator,
pending: std.StringHashMapUnmanaged(std.ArrayList(*Transfer)) = .empty,

pub fn deinit(self: *Coalescer) void {
    var it = self.pending.iterator();
    while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
    self.pending.deinit(self.allocator);
}

pub const JoinResult = enum { first, joined };

pub fn join(
    self: *Coalescer,
    key: []const u8,
    transfer: *Transfer,
    park_tag: Transfer.ParkedBy,
) !JoinResult {
    const entry = try self.pending.getOrPut(self.allocator, key);
    if (!entry.found_existing) {
        entry.value_ptr.* = .empty;
        errdefer _ = self.pending.remove(key);
        try entry.value_ptr.append(self.allocator, transfer);
        transfer.park(park_tag);
        return .first;
    }

    try entry.value_ptr.append(self.allocator, transfer);
    transfer.park(park_tag);
    return .joined;
}

pub fn take(self: *Coalescer, key: []const u8) ?std.ArrayList(*Transfer) {
    const kv = self.pending.fetchRemove(key) orelse return null;
    return kv.value;
}

pub fn peek(self: *Coalescer, key: []const u8) ?[]const *Transfer {
    const list = self.pending.getPtr(key) orelse return null;
    return list.items;
}

pub fn remove(self: *Coalescer, key: []const u8) void {
    var kv = self.pending.fetchRemove(key) orelse return;
    kv.value.deinit(self.allocator);
}

const testing = std.testing;

fn makeTransfer(allocator: std.mem.Allocator) !*Transfer {
    const t = try allocator.create(Transfer);
    // Park requires it to be .created
    t.*.state = .created;
    return t;
}

test "Coalescer - join: first caller gets .first, key appears in pending with one waiter" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    const t1 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t1);

    const result = try c.join("key-a", t1, .robots);
    try testing.expectEqual(JoinResult.first, result);

    const waiters = c.peek("key-a") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), waiters.len);
    try testing.expectEqual(t1, waiters[0]);
}

test "Coalescer - join: second caller on same key gets .joined, both queued in order" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    const t1 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t1);
    const t2 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t2);

    try testing.expectEqual(JoinResult.first, try c.join("key-a", t1, .robots));
    try testing.expectEqual(JoinResult.joined, try c.join("key-a", t2, .robots));

    const waiters = c.peek("key-a") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), waiters.len);
    try testing.expectEqual(t1, waiters[0]);
    try testing.expectEqual(t2, waiters[1]);
}

test "Coalescer - join: different keys don't share a waiter list" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    const t1 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t1);
    const t2 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t2);

    try testing.expectEqual(JoinResult.first, try c.join("key-a", t1, .robots));
    try testing.expectEqual(JoinResult.first, try c.join("key-b", t2, .robots));

    try testing.expectEqual(@as(usize, 1), (c.peek("key-a") orelse return error.TestUnexpectedResult).len);
    try testing.expectEqual(@as(usize, 1), (c.peek("key-b") orelse return error.TestUnexpectedResult).len);
}

test "Coalescer - peek: missing key returns null, doesn't mutate pending" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    try testing.expectEqual(@as(?[]const *Transfer, null), c.peek("nope"));
}

test "Coalescer - take: removes the key and hands back ownership of the waiter list" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    const t1 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t1);

    _ = try c.join("key-a", t1, .robots);

    var taken = c.take("key-a") orelse return error.TestUnexpectedResult;
    defer taken.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), taken.items.len);
    try testing.expectEqual(t1, taken.items[0]);

    // key is gone now
    try testing.expectEqual(@as(?[]const *Transfer, null), c.peek("key-a"));
    try testing.expectEqual(@as(?std.ArrayList(*Transfer), null), c.take("key-a"));
}

test "Coalescer - remove: drops a pending key and frees its list (errdefer-style cleanup)" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    const t1 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t1);
    const t2 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t2);

    _ = try c.join("key-a", t1, .robots);
    _ = try c.join("key-a", t2, .robots);

    c.remove("key-a");

    try testing.expectEqual(@as(?[]const *Transfer, null), c.peek("key-a"));
}

test "Coalescer - remove: no-op on a key that was never joined" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    // Should not error or panic.
    c.remove("never-existed");
}

test "Coalescer - remove: no-op on a key that was already taken" {
    var c = Coalescer{ .allocator = testing.allocator };
    defer c.deinit();

    const t1 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t1);

    _ = try c.join("key-a", t1, .robots);
    var taken = c.take("key-a") orelse return error.TestUnexpectedResult;
    taken.deinit(testing.allocator);

    // Already removed via take(); remove() should just no-op, not double-free.
    c.remove("key-a");
}

test "Coalescer - deinit: frees any keys left pending without a take/remove" {
    var c = Coalescer{ .allocator = testing.allocator };

    const t1 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t1);
    const t2 = try makeTransfer(testing.allocator);
    defer testing.allocator.destroy(t2);

    _ = try c.join("key-a", t1, .robots);
    _ = try c.join("key-b", t2, .robots);

    // No take()/remove() calls — deinit must clean up both lists itself.
    // (testing.allocator will flag a leak if it doesn't.)
    c.deinit();
}
