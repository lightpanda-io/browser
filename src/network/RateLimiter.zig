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
const log = lp.log;

const Network = @import("Network.zig");

const Allocator = std.mem.Allocator;

const RateLimiter = @This();

// The interval grows by one base interval every `burst * RAMP_BURSTS`
// navigations: the more we ask a host, the more we space our requests.
pub const RAMP_BURSTS: u64 = 10;

// Each `COOLDOWN_INTERVALS` base intervals a host is left alone forgives one
// navigation of pressure.
pub const COOLDOWN_INTERVALS: u64 = 10;

// The interval never grows beyond `MAX_INTERVALS` base intervals.
pub const MAX_INTERVALS: u64 = 60;

// A host is spaced by at least `TTFB_FACTOR` times its (smoothed) server
// time: the slower it answers, the more we leave it alone.
pub const TTFB_FACTOR: u64 = 2;

// Smoothing of the server time: each new sample weighs 1 / TTFB_SMOOTHING.
pub const TTFB_SMOOTHING: u64 = 4;

// A host served by git web is spaced by at least `GIT_INTERVALS` base
// intervals: every page costs it git operations.
pub const GIT_INTERVALS: u64 = 10;

allocator: Allocator,

// Minimum gap between two navigations to the same host.
interval_ms: u64,

// Burst tolerance (GCRA tau): how far ahead of "now" a host's theoretical
// arrival time may run before a navigation has to wait. (burst - 1) *
// interval_ms, so burst = 1 means strict spacing. Always in units of the
// base interval: a busy host's burst is spent faster.
tau: u64,

// The four fields below are not constants: they are derived in init from
// the --http-nav-delay and --http-nav-burst flags and the constants above.

// Pressure units per extra base interval (see RAMP_BURSTS).
ramp_step: u64,

// Idle time forgiving one unit of pressure (see COOLDOWN_INTERVALS).
cooldown_ms: u64,

// Cap on the effective interval (see MAX_INTERVALS).
max_ms: u64,

// Pressure at which the cap is reached; pressure never grows past it, so a
// host hammered for hours still recovers in bounded time.
pressure_max: u64,

// hostname (no port) -> per-host state
hosts: Network.HostHashMap(Host) = .empty,

mutex: std.Io.Mutex = .init,

// Idle entries are swept once the map reaches this size
sweep_at: usize = 256,

const Host = struct {
    // Theoretical arrival time (TAT): the time the host's reservations would
    // have reached if every one had been spaced by its interval. A host is
    // idle once its TAT is in the past.
    tat: u64,

    // Leaky bucket of recent navigations. Each one adds 1, each `cooldown_ms` of
    // idle time removes 1.
    pressure: u64,

    // Cooldown clock: the time up to which idle time has already been credited
    // to `pressure`. Advanced by whole `cooldown_ms` steps so no idle time is
    // lost to rounding.
    clock: u64,

    // Smoothed server time (time to first byte, excluding connect) of the
    // host's last responses. 0 until the first response.
    ttfb_ms: u64,

    // Minimum interval forced on the host (see setFloor). 0 until set.
    floor_ms: u64,
};

pub fn init(allocator: Allocator, interval_ms: u64, burst: u32) RateLimiter {
    const b: u64 = @max(burst, 1);
    const ramp_step = b * RAMP_BURSTS;
    return .{
        .allocator = allocator,
        .interval_ms = interval_ms,
        .tau = interval_ms * (b - 1),
        .ramp_step = ramp_step,
        .cooldown_ms = interval_ms * COOLDOWN_INTERVALS,
        .max_ms = interval_ms * MAX_INTERVALS,
        .pressure_max = (MAX_INTERVALS - 1) * ramp_step,
    };
}

pub fn deinit(self: *RateLimiter) void {
    var it = self.hosts.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.hosts.deinit(self.allocator);
}

// Reserve the next navigation slot for the given host. Returns the time the
// request can run at (can be 0, for now).
pub fn reserve(self: *RateLimiter, host: []const u8, now: u64) !u64 {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    const gop = try self.hosts.getOrPut(self.allocator, host);
    if (gop.found_existing) {
        const h = gop.value_ptr;
        self.cooldown(h, now);

        const interval = self.intervalFor(h);
        const start = @max(now, h.tat -| self.tau);
        h.tat = @max(h.tat, start) + interval;
        h.pressure = @min(h.pressure + 1, self.pressure_max);
        log.debug(.rate_limit, "navigation reserved", .{
            .host = host,
            .pressure = h.pressure,
            .interval_ms = interval,
            .wait_ms = start - now,
        });
        return start;
    }

    gop.key_ptr.* = self.allocator.dupe(u8, host) catch |err| {
        self.hosts.removeByPtr(gop.key_ptr);
        return err;
    };
    gop.value_ptr.* = .{
        .tat = now + self.interval_ms,
        .pressure = 1,
        .clock = now,
        .ttfb_ms = 0,
        .floor_ms = 0,
    };

    if (self.hosts.count() >= self.sweep_at) {
        self.sweep(now);
    }
    return now;
}

// Record the server time of a response from the host, and push its next
// slot after the response: a host slower than its interval would otherwise
// be hit again as soon as it answers.
pub fn observe(self: *RateLimiter, host: []const u8, ttfb_ms: u64, now: u64) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    // Unknown host: it was swept, or never throttled. Nothing to adjust.
    const h = self.hosts.getPtr(host) orelse return;

    if (h.ttfb_ms == 0) {
        h.ttfb_ms = ttfb_ms;
    } else {
        h.ttfb_ms = (h.ttfb_ms * (TTFB_SMOOTHING - 1) + ttfb_ms) / TTFB_SMOOTHING;
    }

    // reserve() spaces starts by TTFB_FACTOR * ttfb. The response arrived
    // one ttfb after the start, so the rest of that spacing must still
    // elapse after the response.
    const rest = @min((TTFB_FACTOR - 1) * h.ttfb_ms, self.max_ms);
    h.tat = @max(h.tat, now + rest);
    log.debug(.rate_limit, "response observed", .{
        .host = host,
        .ttfb_ms = ttfb_ms,
        .smoothed_ttfb_ms = h.ttfb_ms,
    });
}

pub fn observeGenerator(self: *RateLimiter, host: []const u8, generator: []const u8) void {
    // a cgit host is throttled, since every page costs it git operations.
    if (!std.ascii.startsWithIgnoreCase(generator, "cgit")) {
        return;
    }

    const floor_ms = RateLimiter.GIT_INTERVALS * self.interval_ms;
    log.debug(.rate_limit, "generator rule", .{ .host = host, .generator = generator, .floor_ms = floor_ms });
    self.setFloor(host, floor_ms);
}

// Force a minimum interval on a host, whatever its pressure and server time.
// The next reserve() picks it up. Capped at `max_ms` like the other terms.
pub fn setFloor(self: *RateLimiter, host: []const u8, floor_ms: u64) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    // Unknown host: it was swept, or never throttled. Nothing to adjust.
    const h = self.hosts.getPtr(host) orelse return;
    h.floor_ms = floor_ms;
    log.debug(.rate_limit, "interval floor", .{
        .host = host,
        .floor_ms = floor_ms,
    });
}

// Effective interval for a host: one extra base interval per full
// `ramp_step` of navigations, never less than `TTFB_FACTOR` times the host's
// server time nor than its floor, capped at `max_ms`.
fn intervalFor(self: *const RateLimiter, h: *const Host) u64 {
    const pressure = self.interval_ms * (1 + h.pressure / self.ramp_step);
    return @min(@max(pressure, TTFB_FACTOR * h.ttfb_ms, h.floor_ms), self.max_ms);
}

// Credit the idle time since the host's cooldown clock to its pressure.
fn cooldown(self: *const RateLimiter, h: *Host, now: u64) void {
    const steps = (now -| h.clock) / self.cooldown_ms;
    if (steps == 0) {
        return;
    }
    if (steps >= h.pressure) {
        h.pressure = 0;
        h.clock = now;
        return;
    }
    h.pressure -= steps;
    h.clock += steps * self.cooldown_ms;
}

// Drop every host whose TAT is already in the past and whose pressure has
// fully cooled down.
// Caller holds the mutex.
fn sweep(self: *RateLimiter, now: u64) void {
    var it = self.hosts.iterator();
    while (it.next()) |entry| {
        const h = entry.value_ptr.*;
        if (h.tat > now) {
            continue;
        }
        if ((now -| h.clock) / self.cooldown_ms < h.pressure) {
            continue;
        }
        const key = entry.key_ptr.*;
        self.hosts.removeByPtr(entry.key_ptr);
        self.allocator.free(key);
    }

    if (self.hosts.count() >= self.sweep_at) {
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
    try testing.expectEqual(2, rl.hosts.count());
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
    try testing.expectEqual(10, strict.ramp_step);
}

test "RateLimiter: pressure ramp" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();

    // 10 navigations queued at once: the host is now under 10 units of
    // pressure (ramp_step for burst = 1), so the 11th is spaced by 2x the
    // base interval, and the 21st by 3x.
    var last: u64 = 0;
    for (0..10) |_| {
        last = try rl.reserve("a.test", 1000);
    }
    try testing.expectEqual(1900, last);
    try testing.expectEqual(10, rl.hosts.get("a.test").?.pressure);

    try testing.expectEqual(2000, try rl.reserve("a.test", 1000));
    try testing.expectEqual(2200, try rl.reserve("a.test", 1000));

    for (0..9) |_| {
        last = try rl.reserve("a.test", 1000);
    }
    try testing.expectEqual(4000, last);
    try testing.expectEqual(4300, try rl.reserve("a.test", 1000));
}

test "RateLimiter: pressure cooldown" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();

    for (0..10) |_| {
        _ = try rl.reserve("a.test", 1000);
    }
    // 10 units of pressure cool down in 10 * cooldown_ms (1000ms each)
    try testing.expectEqual(10, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(1000, rl.hosts.get("a.test").?.clock);

    // half-way: 5 units forgiven, the spacing is back below the ramp step
    try testing.expectEqual(6000, try rl.reserve("a.test", 6000));
    try testing.expectEqual(6, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(6000, rl.hosts.get("a.test").?.clock);
    try testing.expectEqual(6100, try rl.reserve("a.test", 6000));

    // partial idle time is not lost: 999ms short of a step forgives nothing,
    // 1ms more forgives one and only moves the clock by a whole step
    try testing.expectEqual(6999, try rl.reserve("a.test", 6999));
    try testing.expectEqual(8, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(7099, try rl.reserve("a.test", 7000));
    try testing.expectEqual(8, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(7000, rl.hosts.get("a.test").?.clock);

    // fully idle: pressure is gone and the clock catches up
    try testing.expectEqual(100_000, try rl.reserve("a.test", 100_000));
    try testing.expectEqual(1, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(100_000, rl.hosts.get("a.test").?.clock);
}

test "RateLimiter: pressure cap" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();

    // hammer the host: the interval grows up to 60x the base and no further
    var prev: u64 = 0;
    var max_gap: u64 = 0;
    for (0..2000) |_| {
        const t = try rl.reserve("a.test", 1000);
        if (prev != 0) {
            max_gap = @max(max_gap, t - prev);
        }
        prev = t;
    }
    try testing.expectEqual(6000, max_gap);
    try testing.expectEqual(rl.pressure_max, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(6000, rl.intervalFor(&.{ .tat = 0, .pressure = rl.pressure_max, .clock = 0, .ttfb_ms = 0, .floor_ms = 0 }));
    try testing.expectEqual(6000, rl.intervalFor(&.{ .tat = 0, .pressure = rl.pressure_max * 2, .clock = 0, .ttfb_ms = 0, .floor_ms = 0 }));
}

test "RateLimiter: interval floor" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();

    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));

    // the floor wins over the 100ms pressure term
    rl.setFloor("a.test", 1000);
    try testing.expectEqual(1100, try rl.reserve("a.test", 1000));
    try testing.expectEqual(2100, try rl.reserve("a.test", 1000));

    // a slower server time still wins over the floor
    rl.observe("a.test", 800, 2000);
    try testing.expectEqual(3100, try rl.reserve("a.test", 2000));
    try testing.expectEqual(4700, try rl.reserve("a.test", 2000));

    // the floor is capped like the other terms (60 x base)
    rl.setFloor("a.test", 100_000);
    try testing.expectEqual(10_000, try rl.reserve("a.test", 10_000));
    try testing.expectEqual(16_000, try rl.reserve("a.test", 10_000));

    // an unknown host is ignored
    rl.setFloor("b.test", 1000);
    try testing.expect(rl.hosts.get("b.test") == null);
}

test "RateLimiter: slow host" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();

    // first navigation at 1000, the server takes 300ms to answer
    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));
    rl.observe("a.test", 300, 1300);
    try testing.expectEqual(300, rl.hosts.get("a.test").?.ttfb_ms);

    // the TAT (1100) was already past: the next slot is pushed one ttfb
    // after the response, and starts are now spaced by 2 x ttfb
    try testing.expectEqual(1600, try rl.reserve("a.test", 1300));
    try testing.expectEqual(2200, try rl.reserve("a.test", 1300));

    // a fast response does not push anything, and the smoothed ttfb comes
    // down slowly: (300 * 3 + 0) / 4
    rl.observe("a.test", 0, 1900);
    try testing.expectEqual(2800, rl.hosts.get("a.test").?.tat);
    try testing.expectEqual(225, rl.hosts.get("a.test").?.ttfb_ms);
    try testing.expectEqual(2800, try rl.reserve("a.test", 2600));
    try testing.expectEqual(2800 + 450, rl.hosts.get("a.test").?.tat);

    // the ttfb term is capped like the pressure one (60 x base)
    rl.observe("a.test", 100_000, 3000);
    try testing.expectEqual(3000 + 6000, rl.hosts.get("a.test").?.tat);
    try testing.expectEqual(9000, try rl.reserve("a.test", 9000));
    try testing.expectEqual(9000 + 6000, try rl.reserve("a.test", 9000));

    // an unknown host is ignored
    rl.observe("b.test", 300, 3000);
    try testing.expect(rl.hosts.get("b.test") == null);
}

test "RateLimiter: sweep" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();
    rl.sweep_at = 4;

    var buf: [16]u8 = undefined;
    for (0..3) |i| {
        _ = try rl.reserve(try std.fmt.bufPrint(&buf, "h{d}.test", .{i}), 1000);
    }
    try testing.expectEqual(3, rl.hosts.count());

    // 4th insert reaches sweep_at; nothing is idle yet, so the threshold grows
    _ = try rl.reserve("h3.test", 1000);
    try testing.expectEqual(4, rl.hosts.count());
    try testing.expectEqual(8, rl.sweep_at);

    for (4..7) |i| {
        _ = try rl.reserve(try std.fmt.bufPrint(&buf, "h{d}.test", .{i}), 1000);
    }
    try testing.expectEqual(7, rl.hosts.count());

    // hits sweep_at again, far in the future: every earlier host is idle
    try testing.expectEqual(9000, try rl.reserve("h7.test", 9000));
    try testing.expectEqual(1, rl.hosts.count());
    try testing.expectEqual(8, rl.sweep_at);
    // and the survivor keeps its reservation
    try testing.expectEqual(9100, try rl.reserve("h7.test", 9000));
}

test "RateLimiter: sweep keeps pressured hosts" {
    var rl = RateLimiter.init(testing.allocator, 100, 1);
    defer rl.deinit();
    rl.sweep_at = 2;

    // 5 units of pressure on a.test: it needs 5000ms of idle time to be
    // forgotten, well after its TAT (1500) is in the past
    var at: u64 = 1000;
    for (0..5) |_| {
        at = try rl.reserve("a.test", at);
    }

    // a sweep at 3000 keeps it (and doubles the threshold)
    _ = try rl.reserve("b.test", 3000);
    try testing.expectEqual(2, rl.hosts.count());
    try testing.expectEqual(4, rl.sweep_at);

    // a sweep once the pressure has cooled down drops it
    rl.sweep_at = 2;
    _ = try rl.reserve("c.test", 10_000);
    try testing.expect(rl.hosts.get("a.test") == null);
}
