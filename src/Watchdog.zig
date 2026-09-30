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

const Env = @import("browser/js/Env.zig");

const log = lp.log;

// How often the checker thread scans the entries.
const CHECK_INTERVAL_NS = 1 * std.time.ns_per_s;

// The "watchdog stall script" line is logged by the termination interrupt,
// which only runs once the worker is back in JavaScript. If it's still pending
// this long after the stall was detected, the worker is stuck in native code:
// say so from here, or the stall leaves no trace above debug.
const NATIVE_STALL_REPORT_MS = 5_000;

const Watchdog = @This();

// null == disabled: no thread, register/unregister no-op.
timeout_ms: ?u32,
shutdown: bool = false,
thread: ?std.Thread = null,
mutex: std.Io.Mutex = .init,
cond: std.Io.Condition = .init,
entries: std.DoublyLinkedList = .{},

// Embedded in Browser; must outlive the register/unregister window.
pub const Entry = struct {
    env: *Env,
    heartbeat: *Heartbeat,
    fired: bool = false,
    // Set once the current stall has been reported as native (see
    // NATIVE_STALL_REPORT_MS). Reset when a new stall fires.
    native_reported: bool = false,
    registered: bool = false,
    node: std.DoublyLinkedList.Node = .{},
};

pub fn init(timeout_ms: ?u32) Watchdog {
    return .{ .timeout_ms = timeout_ms };
}

pub fn deinit(self: *Watchdog) void {
    const thread = self.thread orelse return;
    {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.shutdown = true;
        self.cond.signal(lp.io);
    }
    thread.join();
}

// Call once the Watchdog is at its final address (init returns by value).
pub fn start(self: *Watchdog) !void {
    if (self.timeout_ms == null) {
        return;
    }
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn register(self: *Watchdog, entry: *Entry) void {
    if (self.timeout_ms == null) {
        return;
    }

    {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.entries.append(&entry.node);
    }
    entry.registered = true;
}

pub fn unregister(self: *Watchdog, entry: *Entry) void {
    if (entry.registered == false) {
        return;
    }

    {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.entries.remove(&entry.node);
    }
    entry.registered = false;
}

fn run(self: *Watchdog) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    while (true) {
        lp.timedWait(&self.cond, &self.mutex, CHECK_INTERVAL_NS) catch {};
        if (self.shutdown) {
            return;
        }
        self.scan(lp.datetime.milliTimestamp(.boot));
    }
}

// Called with the mutex held.
fn scan(self: *Watchdog, now: u64) void {
    const timeout_ms: u64 = self.timeout_ms.?;

    var node = self.entries.first;
    while (node) |n| : (node = n.next) {
        const entry: *Entry = @fieldParentPtr("node", n);
        const heartbeat = entry.heartbeat;

        if (heartbeat.wait_depth.load(.acquire) > 0) {
            // The entry is in a controlled (e.g. non-JS) wait
            entry.fired = false;
            continue;
        }

        const last = heartbeat.last_activity.load(.acquire);
        if (last == 0) {
            // disarmed: no page work can be running
            continue;
        }

        const stalled_ms = now -| last;
        if (stalled_ms < timeout_ms) {
            entry.fired = false;
            continue;
        }

        if (entry.fired == false) {
            entry.fired = true;
            entry.native_reported = false;
            log.debug(.watchdog, "watchdog stall", .{ .stalled_ms = stalled_ms });
            // The worker logs "watchdog stall script" (URL and JS stack) when
            // the termination interrupt lands.
            entry.env.requestTerminateForStall(stalled_ms);
            continue;
        }

        if (entry.native_reported) {
            continue;
        }
        const requested_at = entry.env.pendingStallReport() orelse continue;
        const pending_ms = now -| requested_at;
        if (pending_ms >= NATIVE_STALL_REPORT_MS) {
            entry.native_reported = true;
            log.warn(.watchdog, "watchdog stall native", .{
                .stalled_ms = stalled_ms,
                .pending_ms = pending_ms,
            });
        }
    }
}

// Written by the watched worker thread, read by the Watchdog thread.
pub const Heartbeat = struct {
    // > 0 while the worker is parked in a wait. Counterintuitive, but waiting
    // can be nested (background task (wait_depth += 1) which runs microtask
    // which does a syncRequest (wait_depth += 1). As long as we're waiting it
    // means we aren't executing JavaScript and thus can't be in an endless JS
    // loop.
    wait_depth: std.atomic.Value(u32) = .init(0),

    // The last time we saw some non-JS activity. 0 means disarmed: the worker
    // is somewhere no page work can be running — before its first Runner tick
    // (e.g. still in the CDP handshake read), or idle-pumping a session with
    // no pages (MCP/agent between commands, see Session.idleSlice) — so the
    // checker skips it.
    last_activity: std.atomic.Value(u64) = .init(0),

    pub fn touch(self: *Heartbeat) void {
        self.last_activity.store(lp.datetime.milliTimestamp(.boot), .release);
    }

    pub fn disarm(self: *Heartbeat) void {
        self.last_activity.store(0, .release);
    }

    // Entering a planned wait (e.g. network poll)
    pub fn enterWait(self: *Heartbeat) void {
        self.touch();
        _ = self.wait_depth.fetchAdd(1, .release);
    }

    // Existing a planned wait
    pub fn exitWait(self: *Heartbeat) void {
        self.touch();
        _ = self.wait_depth.fetchSub(1, .release);
    }
};

const testing = @import("testing.zig");
test "Watchdog: a stall that never returns to JavaScript is reported once" {
    // Only the native warn: the first line is debug, and the termination
    // interrupt never lands because no JavaScript runs.
    testing.expectLog(&.{.watchdog});

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const env = frame.js.env;
    defer env.cancelTerminate();

    var watchdog = Watchdog.init(30_000);
    var heartbeat: Heartbeat = .{};
    var entry: Entry = .{ .env = env, .heartbeat = &heartbeat };
    watchdog.register(&entry);
    defer watchdog.unregister(&entry);

    // The report's request time comes from the real clock, so the stall is
    // placed in the past and scans run at (or just after) the real now.
    const now = lp.datetime.milliTimestamp(.boot);
    heartbeat.last_activity.store(now - 31_000, .release);

    watchdog.scan(now - 2_000);
    try testing.expectEqual(false, entry.fired);

    watchdog.scan(now);
    try testing.expectEqual(true, entry.fired);
    try testing.expect(env.pendingStallReport() != null);

    // Still pending, but not for long enough to call it native.
    watchdog.scan(now + 2_000);
    try testing.expectEqual(false, entry.native_reported);

    watchdog.scan(now + 6_000);
    try testing.expectEqual(true, entry.native_reported);

    // Reported once per stall.
    watchdog.scan(now + 7_000);

    // Activity ends the stall.
    heartbeat.last_activity.store(now + 7_000, .release);
    watchdog.scan(now + 8_000);
    try testing.expectEqual(false, entry.fired);
}

test "Watchdog: no native report once the script report has been logged" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const env = frame.js.env;
    defer env.cancelTerminate();

    var watchdog = Watchdog.init(30_000);
    var heartbeat: Heartbeat = .{};
    var entry: Entry = .{ .env = env, .heartbeat = &heartbeat };
    watchdog.register(&entry);
    defer watchdog.unregister(&entry);

    const now = lp.datetime.milliTimestamp(.boot);
    heartbeat.last_activity.store(now - 31_000, .release);
    watchdog.scan(now);

    // Stands in for the interrupt landing: the worker consumed the report.
    _ = env.stall_report_requested_at.swap(0, .acq_rel);

    watchdog.scan(now + 9_000);
    try testing.expectEqual(false, entry.native_reported);
}
