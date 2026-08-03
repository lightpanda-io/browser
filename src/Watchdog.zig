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

// How often the checker thread scans ordinary liveness heartbeats. Explicit
// execution deadlines shorten this wait and wake the thread when armed.
const CHECK_INTERVAL_NS = 1 * std.time.ns_per_s;
// The condition wait uses the awake clock while command deadlines use boot
// time (which includes suspend). Rescan active finite deadlines at least once
// per second so a resume observes an expired boot-time deadline promptly.
const MAX_DEADLINE_WAIT_NS = std.time.ns_per_s;

const Watchdog = @This();

// null disables ordinary stall detection. WebDriver explicitly enables the
// thread before creating a browser so per-command deadlines remain available.
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
    execution_active: std.atomic.Value(bool) = .init(false),
    execution_deadline_ns: std.atomic.Value(u64) = .init(0),
    execution_deadline_fired: std.atomic.Value(bool) = .init(false),
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
    if (self.timeout_ms == null) return;
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

/// WebDriver calls this before creating its first browser. This preserves the
/// thread-free `--watchdog-ms=0` behavior for every other mode.
pub fn enableExecutionDeadlines(self: *Watchdog) !void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    if (self.thread != null) return;
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn register(self: *Watchdog, entry: *Entry) void {
    if (self.thread == null) return;
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
        entry.execution_active.store(false, .release);
        entry.execution_deadline_ns.store(0, .release);
        entry.execution_deadline_fired.store(false, .release);
        self.entries.remove(&entry.node);
        self.cond.signal(lp.io);
    }
    entry.registered = false;
}

pub fn armExecutionDeadline(self: *Watchdog, entry: *Entry, timeout_ms: ?u64) void {
    std.debug.assert(self.thread != null);
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    entry.execution_active.store(true, .release);
    entry.execution_deadline_fired.store(false, .release);
    entry.fired = false;
    entry.heartbeat.touch();
    const deadline = if (timeout_ms) |timeout|
        @as(u64, @intCast(std.Io.Timestamp.now(lp.io, .boot).toNanoseconds())) +| timeout *| std.time.ns_per_ms
    else
        0;
    entry.execution_deadline_ns.store(deadline, .release);
    self.cond.signal(lp.io);
}

pub fn executionDeadlineFired(_: *const Watchdog, entry: *const Entry) bool {
    return entry.execution_deadline_fired.load(.acquire);
}

pub fn disarmExecutionDeadline(self: *Watchdog, entry: *Entry) bool {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    entry.execution_active.store(false, .release);
    entry.execution_deadline_ns.store(0, .release);
    const fired = entry.execution_deadline_fired.swap(false, .acq_rel);
    entry.fired = false;
    entry.heartbeat.touch();
    self.cond.signal(lp.io);
    return fired;
}

fn run(self: *Watchdog) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    while (true) {
        if (self.shutdown) {
            return;
        }

        const now: u64 = @intCast(std.Io.Timestamp.now(lp.io, .boot).toNanoseconds());
        const now_ms = lp.datetime.milliTimestamp(.boot);
        var next_wait_ns: ?u64 = if (self.timeout_ms != null) CHECK_INTERVAL_NS else null;
        var node = self.entries.first;
        while (node) |n| : (node = n.next) {
            const entry: *Entry = @fieldParentPtr("node", n);
            if (entry.execution_active.load(.acquire)) {
                const execution_deadline = entry.execution_deadline_ns.load(.acquire);
                if (!entry.execution_deadline_fired.load(.acquire)) {
                    if (execution_deadline != 0 and now >= execution_deadline) {
                        entry.execution_deadline_fired.store(true, .release);
                        entry.env.requestExecutionDeadlineTerminate();
                    } else if (execution_deadline != 0) {
                        const remaining_ns = execution_deadline - now;
                        next_wait_ns = if (next_wait_ns) |current|
                            @min(current, remaining_ns)
                        else
                            remaining_ns;
                    }
                }
                // An explicit command deadline supersedes the generic stall
                // limit, including a null (infinite) WebDriver timeout.
                continue;
            }

            const timeout_ms: u64 = self.timeout_ms orelse continue;
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

            const stalled_ms = now_ms -| last;
            if (stalled_ms < timeout_ms) {
                entry.fired = false;
                continue;
            }

            if (entry.fired == false) {
                entry.fired = true;
                log.err(.app, "watchdog stall", .{ .stalled_ms = stalled_ms });
                entry.env.requestTerminate();
            }
        }
        const wait_ns: ?u64 = if (next_wait_ns) |ns|
            @min(@max(ns, 1), MAX_DEADLINE_WAIT_NS)
        else
            null;
        if (wait_ns) |timeout_ns| {
            lp.timedWait(&self.cond, &self.mutex, timeout_ns) catch {};
        } else {
            self.cond.waitUncancelable(lp.io, &self.mutex);
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

test "Watchdog: disabled mode stays thread-free unless deadlines are enabled" {
    var disabled = Watchdog.init(null);
    try disabled.start();
    defer disabled.deinit();
    try std.testing.expect(disabled.thread == null);

    try disabled.enableExecutionDeadlines();
    try std.testing.expect(disabled.thread != null);
}
