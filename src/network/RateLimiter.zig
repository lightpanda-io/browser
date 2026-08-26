// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const Network = @import("Network.zig");

const Allocator = std.mem.Allocator;

const RateLimiter = @This();

allocator: Allocator,

// Sustained minimum gap between two navigations to the same host.
interval_ms: u64,

// Burst tolerance (GCRA tau): how far ahead of "now" a host's theoretical
// arrival time may run before a navigation has to wait. (burst - 1) *
// interval_ms, so burst = 1 means strict spacing.
tau: u64,

// hostname (no port) -> theoretical arrival time (TAT): the time the host's
// reservations would have reached if every one had been spaced by
// interval_ms. A host is idle once its TAT is in the past.
next: Network.HostHashMap(u64) = .empty,

mutex: std.Io.Mutex = .init,

// Idle entries are swept once the map reaches this size
sweep_at: usize = 256,

pub fn init(allocator: Allocator, interval_ms: u64, burst: u32) RateLimiter {
    return .{
        .allocator = allocator,
        .interval_ms = interval_ms,
        .tau = interval_ms * (@max(burst, 1) - 1),
    };
}

pub fn deinit(self: *RateLimiter) void {
    var it = self.next.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.next.deinit(self.allocator);
}

// Reserve the next navigation slot for the given host. Returns the time the
// request can run at (can be 0, for now).
pub fn reserve(self: *RateLimiter, host: []const u8, now: u64) !u64 {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    const gop = try self.next.getOrPut(self.allocator, host);
    if (gop.found_existing) {
        const tat = gop.value_ptr.*;
        const start = @max(now, tat -| self.tau);
        gop.value_ptr.* = @max(tat, start) + self.interval_ms;
        return start;
    }

    gop.key_ptr.* = self.allocator.dupe(u8, host) catch |err| {
        self.next.removeByPtr(gop.key_ptr);
        return err;
    };
    gop.value_ptr.* = now + self.interval_ms;

    if (self.next.count() >= self.sweep_at) {
        self.sweep(now);
    }
    return now;
}

// Drop every host whose TAT is already in the past.
// Caller holds the mutex.
fn sweep(self: *RateLimiter, now: u64) void {
    var it = self.next.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* > now) {
            continue;
        }
        const key = entry.key_ptr.*;
        self.next.removeByPtr(entry.key_ptr);
        self.allocator.free(key);
    }

    if (self.next.count() >= self.sweep_at) {
        // we don't want reserve() to turn into an O(N), constantly sweeping
        // what it can't clean. So we increase the size of what we'll hold
        self.sweep_at *= 2;
    }
}

const testing = @import("../testing.zig");
test "RateLimiter: reserve" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();

    // idle host starts now, then serializes at the interval
    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));
    try testing.expectEqual(1100, try rl.reserve("a.test", 1000));
    try testing.expectEqual(1200, try rl.reserve("a.test", 1050));

    // other hosts are independent, keys are case-insensitive
    try testing.expectEqual(1000, try rl.reserve("b.test", 1000));
    try testing.expectEqual(1100, try rl.reserve("B.TEST", 1000));

    // once the interval has elapsed, the host is idle again
    try testing.expectEqual(5000, try rl.reserve("a.test", 5000));
    try testing.expectEqual(2, rl.next.count());
}

test "RateLimiter: burst" {
    var rl = RateLimiter.init(testing.allocator, 100, 3);
    defer rl.deinit();

    // an idle host absorbs `burst` navigations at once
    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));
    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));
    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));
    // then spaces them by the interval
    try testing.expectEqual(1100, try rl.reserve("a.test", 1000));
    try testing.expectEqual(1200, try rl.reserve("a.test", 1000));
    try testing.expectEqual(1300, try rl.reserve("a.test", 1250));

    // the burst allowance refills one slot per interval: at 1500 the TAT
    // (1600) is only one interval ahead, so one extra slot is free
    try testing.expectEqual(1500, try rl.reserve("a.test", 1500));
    try testing.expectEqual(1500, try rl.reserve("a.test", 1500));
    try testing.expectEqual(1600, try rl.reserve("a.test", 1500));

    // fully idle again once the TAT is in the past
    try testing.expectEqual(5000, try rl.reserve("a.test", 5000));
    try testing.expectEqual(5000, try rl.reserve("a.test", 5000));
    try testing.expectEqual(5000, try rl.reserve("a.test", 5000));
    try testing.expectEqual(5100, try rl.reserve("a.test", 5000));

    // burst = 0 is treated as 1
    var strict = RateLimiter.init(testing.allocator, 100, 0);
    defer strict.deinit();
    try testing.expectEqual(0, strict.tau);
}

test "RateLimiter: sweep" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();
    rl.sweep_at = 4;

    var buf: [16]u8 = undefined;
    for (0..3) |i| {
        _ = try rl.reserve(try std.fmt.bufPrint(&buf, "h{d}.test", .{i}), 1000);
    }
    try testing.expectEqual(3, rl.next.count());

    // 4th insert reaches sweep_at; nothing is idle yet, so the threshold grows
    _ = try rl.reserve("h3.test", 1000);
    try testing.expectEqual(4, rl.next.count());
    try testing.expectEqual(8, rl.sweep_at);

    for (4..7) |i| {
        _ = try rl.reserve(try std.fmt.bufPrint(&buf, "h{d}.test", .{i}), 1000);
    }
    try testing.expectEqual(7, rl.next.count());

    // hits sweep_at again, far in the future: every earlier host is idle
    try testing.expectEqual(9000, try rl.reserve("h7.test", 9000));
    try testing.expectEqual(1, rl.next.count());
    try testing.expectEqual(8, rl.sweep_at);
    // and the survivor keeps its reservation
    try testing.expectEqual(9100, try rl.reserve("h7.test", 9000));
}
