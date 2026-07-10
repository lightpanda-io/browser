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
const milliTimestamp = @import("datetime.zig").milliTimestamp;

// How often the checker thread scans the entries.
const CHECK_INTERVAL_NS = 1 * std.time.ns_per_s;

const Watchdog = @This();

// null == disabled: no thread, register/unregister no-op.
timeout_ms: ?u32,
shutdown: bool = false,
thread: ?std.Thread = null,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
entries: std.DoublyLinkedList = .{},

// Embedded in Browser; must outlive the register/unregister window.
pub const Entry = struct {
    env: *Env,
    heartbeat: *Heartbeat,
    fired: bool = false,
    registered: bool = false,
    node: std.DoublyLinkedList.Node = .{},
};

pub fn init(timeout_ms: ?u32) Watchdog {
    return .{ .timeout_ms = timeout_ms };
}

pub fn deinit(self: *Watchdog) void {
    const thread = self.thread orelse return;
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown = true;
        self.cond.signal();
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
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.append(&entry.node);
    }
    entry.registered = true;
}

pub fn unregister(self: *Watchdog, entry: *Entry) void {
    if (entry.registered == false) {
        return;
    }

    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.remove(&entry.node);
    }
    entry.registered = false;
}

fn run(self: *Watchdog) void {
    const timeout_ms: u64 = self.timeout_ms.?;

    self.mutex.lock();
    defer self.mutex.unlock();

    while (true) {
        self.cond.timedWait(&self.mutex, CHECK_INTERVAL_NS) catch {};
        if (self.shutdown) {
            return;
        }

        const now = milliTimestamp(.monotonic);
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
                log.err(.app, "watchdog stall", .{ .stalled_ms = stalled_ms });
                entry.env.requestTerminate();
            }
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
        self.last_activity.store(milliTimestamp(.monotonic), .release);
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
