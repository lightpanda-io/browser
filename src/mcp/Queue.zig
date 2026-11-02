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

//! Intrusive FIFO handed between threads: a producer pushes work, the
//! consumer pops with a timeout so it can pump between items. The HTTP
//! transport queues request jobs on a session's worker; the stdio transport
//! queues raw messages behind its reader thread.

const std = @import("std");
const lp = @import("lightpanda");

/// `T` must have a `next: ?*T` field; the queue links items through it and
/// leaves it null once popped.
pub fn Queue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        head: ?*T = null,
        tail: ?*T = null,
        closed: bool = false,

        const Self = @This();

        /// Callers push only to an open queue.
        pub fn push(self: *Self, item: *T) void {
            self.mutex.lockUncancelable(lp.io);
            defer self.mutex.unlock(lp.io);
            std.debug.assert(!self.closed);
            item.next = null;
            if (self.tail) |t| t.next = item else self.head = item;
            self.tail = item;
            self.cond.signal(lp.io);
        }

        pub const Pop = union(enum) { item: *T, timeout, closed };

        /// The next item, waiting at most `timeout_ms` (`.timeout` on timeout
        /// or spurious wakeup, so the consumer can pump and retry). `.closed`
        /// only once the queue is closed AND drained, so no pushed item is
        /// ever left behind.
        pub fn pop(self: *Self, timeout_ms: u64) Pop {
            self.mutex.lockUncancelable(lp.io);
            defer self.mutex.unlock(lp.io);
            if (self.head == null) {
                if (self.closed) return .closed;
                if (timeout_ms == 0) return .timeout;
                lp.timedWait(&self.cond, &self.mutex, timeout_ms * std.time.ns_per_ms) catch {};
            }
            const item = self.head orelse return if (self.closed) .closed else .timeout;
            self.head = item.next;
            if (self.head == null) self.tail = null;
            return .{ .item = item };
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lockUncancelable(lp.io);
            defer self.mutex.unlock(lp.io);
            return self.head == null;
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(lp.io);
            defer self.mutex.unlock(lp.io);
            self.closed = true;
            self.cond.signal(lp.io);
        }
    };
}

test "Queue - items come back in order and closed drains fully" {
    // A self-referential type needs container scope.
    const Item = struct {
        const Item = struct { body: u32, next: ?*Item = null };
    }.Item;
    var queue: Queue(Item) = .{};

    var one: Item = .{ .body = 1 };
    var two: Item = .{ .body = 2 };
    var three: Item = .{ .body = 3 };
    queue.push(&one);
    queue.push(&two);
    queue.push(&three);
    queue.close();

    // Even closed, everything pushed before the close comes back.
    try std.testing.expectEqual(@as(u32, 1), queue.pop(0).item.body);
    try std.testing.expectEqual(@as(u32, 2), queue.pop(0).item.body);
    try std.testing.expectEqual(@as(u32, 3), queue.pop(0).item.body);
    try std.testing.expectEqual(Queue(Item).Pop.closed, queue.pop(0));

    // An empty open queue times out without blocking.
    var open: Queue(Item) = .{};
    try std.testing.expectEqual(Queue(Item).Pop.timeout, open.pop(0));
    open.close();
    try std.testing.expectEqual(Queue(Item).Pop.closed, open.pop(0));
}
