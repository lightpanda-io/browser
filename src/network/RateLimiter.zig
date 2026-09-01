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

// In adaptive mode the interval grows with the host's pressure and comes
// back down when the host is left alone. In fixed mode the interval never
// changes: the user asked for an exact spacing with --http-nav-delay.
pub const Mode = enum { fixed, adaptive };

// Base interval used in adaptive mode, when no --http-nav-delay is given.
pub const ADAPTIVE_INTERVAL_MS: u64 = 20;

// In adaptive mode, the interval grows by one base interval every
// `burst * RAMP_BURSTS` navigations: the more we ask a host, the more we
// space our requests.
pub const RAMP_BURSTS: u64 = 10;

// Each `COOLDOWN_INTERVALS` base intervals a host is left alone forgives one
// navigation of pressure.
pub const COOLDOWN_INTERVALS: u64 = 10;

// The interval never grows beyond `MAX_INTERVALS` base intervals.
pub const MAX_INTERVALS: u64 = 60;

// Pressure added, in base intervals, when a host answers 429 or 503: the
// server asked us to back off.
pub const OVERLOAD_INTERVALS: u64 = 5;

// Pressure added, in base intervals, when a host answers another 5xx or
// does not answer at all (timeout, connection error).
pub const FAILURE_INTERVALS: u64 = 1;

// A Retry-After header is honored up to this delay.
pub const RETRY_AFTER_MAX_MS: u64 = 60_000;

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

mode: Mode,

// Pressure at which the cap is reached; pressure never grows past it, so a
// host hammered for hours still recovers in bounded time. 0 in fixed mode:
// pressure never accumulates and the interval stays at interval_ms.
pressure_max: u64,

// hostname (no port) -> per-host state
hosts: Network.HostHashMap(Host) = .empty,

mutex: std.Io.Mutex = .init,

// Idle entries are swept once the map reaches this size
sweep_at: usize = 256,

// Loopback hosts (localhost, 127.0.0.1, [::1]) are exempt: the limiter
// protects remote hosts, not local servers. Tests turn this off to
// throttle a local test server.
exempt_loopback: bool = true,

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
};

pub fn init(allocator: Allocator, interval_ms: u64, burst: u32, mode: Mode) RateLimiter {
    const b: u64 = @max(burst, 1);
    const ramp_step = b * RAMP_BURSTS;
    return .{
        .allocator = allocator,
        .mode = mode,
        .interval_ms = interval_ms,
        .tau = interval_ms * (b - 1),
        .ramp_step = ramp_step,
        .cooldown_ms = interval_ms * COOLDOWN_INTERVALS,
        .max_ms = interval_ms * MAX_INTERVALS,
        .pressure_max = switch (mode) {
            .adaptive => (MAX_INTERVALS - 1) * ramp_step,
            .fixed => 0,
        },
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
    if (self.exempt_loopback and isLoopback(host)) {
        return now;
    }

    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    const gop = try self.hosts.getOrPut(self.allocator, host);
    if (gop.found_existing) {
        const h = gop.value_ptr;
        self.cooldown(h, now);

        const interval = self.intervalFor(h.pressure);
        const start = @max(now, h.tat -| self.tau);
        h.tat = @max(h.tat, start) + interval;
        h.pressure = @min(h.pressure + 1, self.pressure_max);

        const wait = start - now;
        // log.debug(.rate_limit, "navigation reserved", .{
        //     .host = host,
        //     .pressure = h.pressure,
        //     .interval_ms = interval,
        //     .wait_ms = wait,
        // });
        if (wait > 0) {
            const level: lp.log.Level = if (self.mode == .adaptive) .warn else .debug;
            lp.log.log(.rate_limit, level, "navigation delayed", .{
                .host = host,
                .wait_ms = wait,
                .tips = "use `--http-nav-delay 0` to disable the rate limiter",
            });
        }
        return start;
    }

    gop.key_ptr.* = self.allocator.dupe(u8, host) catch |err| {
        self.hosts.removeByPtr(gop.key_ptr);
        return err;
    };
    gop.value_ptr.* = .{
        .tat = now + self.interval_ms,
        .pressure = @min(1, self.pressure_max),
        .clock = now,
    };

    if (self.hosts.count() >= self.sweep_at) {
        self.sweep(now);
    }
    return now;
}

pub const Feedback = struct {
    // HTTP status of the response; 0 when no response arrived (timeout,
    // connection error).
    status: u16 = 0,

    // Retry-After header of the response, when present.
    retry_after_ms: ?u64 = null,
};

// Record the outcome of a throttled navigation. An overloaded or failing
// host gets extra pressure, so the next navigations to it are spaced more.
// Fixed mode ignores feedback: the user asked for an exact spacing.
pub fn observe(self: *RateLimiter, host: []const u8, feedback: Feedback, now: u64) !void {
    if (self.pressure_max == 0) {
        return;
    }
    if (self.exempt_loopback and isLoopback(host)) {
        return;
    }

    const intervals: u64 = switch (feedback.status) {
        // the server explicitly asked to back off
        429, 503 => OVERLOAD_INTERVALS,
        // no response at all, or another server error
        0, 500...502, 504...599 => FAILURE_INTERVALS,
        else => 0,
    };
    if (intervals == 0 and feedback.retry_after_ms == null) {
        return;
    }

    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    // The host can be missing: it was swept, or a redirect landed on a host
    // that was never reserved. Create it, so its feedback is not lost.
    const gop = try self.hosts.getOrPut(self.allocator, host);
    if (!gop.found_existing) {
        gop.key_ptr.* = self.allocator.dupe(u8, host) catch |err| {
            self.hosts.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = .{ .tat = now, .pressure = 0, .clock = now };
    }

    const h = gop.value_ptr;
    self.cooldown(h, now);
    h.pressure = @min(h.pressure + intervals * self.ramp_step, self.pressure_max);
    if (feedback.retry_after_ms) |ms| {
        h.tat = @max(h.tat, now + @min(ms, RETRY_AFTER_MAX_MS));
    }
    log.debug(.rate_limit, "response observed", .{
        .host = host,
        .status = feedback.status,
        .pressure = h.pressure,
        .retry_after_ms = feedback.retry_after_ms,
    });

    if (!gop.found_existing and self.hosts.count() >= self.sweep_at) {
        self.sweep(now);
    }
}

// True for the loopback names URL.getHostname can produce: an IPv6 host
// keeps its brackets ("[::1]").
fn isLoopback(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]");
}

// Effective interval for a host under the given pressure: one extra base
// interval per full `ramp_step` of navigations, capped at `max_ms`.
fn intervalFor(self: *const RateLimiter, pressure: u64) u64 {
    return @min(self.interval_ms * (1 + pressure / self.ramp_step), self.max_ms);
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
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
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
    var rl = RateLimiter.init(testing.allocator, 100, 3, .adaptive);
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
    var strict = RateLimiter.init(testing.allocator, 100, 0, .adaptive);
    defer strict.deinit();
    try testing.expectEqual(0, strict.tau);
    try testing.expectEqual(10, strict.ramp_step);
}

test "RateLimiter: pressure ramp" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
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
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
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
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
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
    try testing.expectEqual(6000, rl.intervalFor(rl.pressure_max));
    try testing.expectEqual(6000, rl.intervalFor(rl.pressure_max * 2));
}

test "RateLimiter: observe overload" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
    defer rl.deinit();

    // a 429 adds 5 base intervals of pressure at once
    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));
    try rl.observe("a.test", .{ .status = 429 }, 1050);
    try testing.expectEqual(51, rl.hosts.get("a.test").?.pressure);

    // navigations are now spaced by 100 * (1 + 51/10) = 600
    try testing.expectEqual(1100, try rl.reserve("a.test", 1100));
    try testing.expectEqual(1700, try rl.reserve("a.test", 1100));

    // Retry-After pushes the next slot directly
    try rl.observe("a.test", .{ .status = 503, .retry_after_ms = 5000 }, 2000);
    try testing.expectEqual(7000, try rl.reserve("a.test", 2100));

    // and is honored up to RETRY_AFTER_MAX_MS only
    try rl.observe("a.test", .{ .status = 429, .retry_after_ms = 3_600_000 }, 10_000);
    try testing.expectEqual(70_000, try rl.reserve("a.test", 10_100));
}

test "RateLimiter: observe failures" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
    defer rl.deinit();

    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));

    // a server error, or no response at all, adds one base interval each
    try rl.observe("a.test", .{ .status = 500 }, 1010);
    try rl.observe("a.test", .{}, 1020);
    try testing.expectEqual(21, rl.hosts.get("a.test").?.pressure);

    // a success adds nothing
    try rl.observe("a.test", .{ .status = 200 }, 1030);
    try testing.expectEqual(21, rl.hosts.get("a.test").?.pressure);
}

test "RateLimiter: observe unknown host" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
    defer rl.deinit();

    // a success on an unknown host records nothing
    try rl.observe("a.test", .{ .status = 200 }, 1000);
    try testing.expect(rl.hosts.get("a.test") == null);

    // an error creates the host: a redirect can land on a host that was
    // never reserved, and its feedback must not be lost
    try rl.observe("a.test", .{ .status = 429, .retry_after_ms = 2000 }, 1000);
    try testing.expectEqual(50, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(3000, try rl.reserve("a.test", 1100));
}

test "RateLimiter: observe fixed mode" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .fixed);
    defer rl.deinit();

    // fixed mode ignores feedback: the user asked for an exact spacing
    try testing.expectEqual(1000, try rl.reserve("a.test", 1000));
    try rl.observe("a.test", .{ .status = 429, .retry_after_ms = 5000 }, 1010);
    try testing.expectEqual(0, rl.hosts.get("a.test").?.pressure);
    try testing.expectEqual(1100, try rl.reserve("a.test", 1050));
}

test "RateLimiter: loopback is exempt" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
    defer rl.deinit();

    // loopback hosts are never delayed and never tracked
    try testing.expectEqual(1000, try rl.reserve("localhost", 1000));
    try testing.expectEqual(1000, try rl.reserve("LOCALHOST", 1000));
    try testing.expectEqual(1000, try rl.reserve("127.0.0.1", 1000));
    try testing.expectEqual(1000, try rl.reserve("[::1]", 1000));
    try rl.observe("127.0.0.1", .{ .status = 429, .retry_after_ms = 5000 }, 1000);
    try testing.expectEqual(0, rl.hosts.count());

    // tests can turn the exemption off to throttle a local server
    rl.exempt_loopback = false;
    try testing.expectEqual(1000, try rl.reserve("127.0.0.1", 1000));
    try testing.expectEqual(1100, try rl.reserve("127.0.0.1", 1000));
}

test "RateLimiter: fixed mode" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .fixed);
    defer rl.deinit();

    // pressure never accumulates: the spacing stays at the base interval,
    // no matter how many navigations the host gets
    var last: u64 = 0;
    for (0..50) |_| {
        last = try rl.reserve("a.test", 1000);
    }
    try testing.expectEqual(1000 + 49 * 100, last);
    try testing.expectEqual(0, rl.hosts.get("a.test").?.pressure);

    // with no pressure to cool down, an idle host is swept as soon as its
    // TAT is in the past
    rl.sweep_at = 2;
    _ = try rl.reserve("b.test", 50_000);
    try testing.expect(rl.hosts.get("a.test") == null);
}

test "RateLimiter: sweep" {
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
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
    var rl = RateLimiter.init(testing.allocator, 100, 1, .adaptive);
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
