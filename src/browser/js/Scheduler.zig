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
const builtin = @import("builtin");
const milliTimestamp = @import("../../datetime.zig").milliTimestamp;

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

const Queue = std.PriorityQueue(Task, void, struct {
    fn compare(_: void, a: Task, b: Task) std.math.Order {
        const time_order = std.math.order(a.run_at, b.run_at);
        if (time_order != .eq) return time_order;
        // Break ties with sequence number to maintain FIFO order
        return std.math.order(a.sequence, b.sequence);
    }
}.compare);

const Scheduler = @This();

_sequence: u64,
low_priority: Queue,
high_priority: Queue,

pub fn init(allocator: std.mem.Allocator) Scheduler {
    return .{
        ._sequence = 0,
        .low_priority = Queue.init(allocator, {}),
        .high_priority = Queue.init(allocator, {}),
    };
}

pub fn deinit(self: *Scheduler) void {
    finalizeTasks(&self.low_priority);
    finalizeTasks(&self.high_priority);
}

pub fn reset(self: *Scheduler) void {
    self.low_priority.clearRetainingCapacity();
    self.high_priority.clearRetainingCapacity();
}

const AddOpts = struct {
    name: []const u8 = "",
    low_priority: bool = false,
    finalizer: ?Finalizer = null,
};
pub fn add(self: *Scheduler, ctx: *anyopaque, cb: Callback, run_in_ms: u32, opts: AddOpts) !void {
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "scheduler.add", .{ .name = opts.name, .run_in_ms = run_in_ms, .low_priority = opts.low_priority });
    }
    var queue = if (opts.low_priority) &self.low_priority else &self.high_priority;
    const seq = self._sequence + 1;
    self._sequence = seq;
    return queue.add(.{
        .ctx = ctx,
        .callback = cb,
        .sequence = seq,
        .name = opts.name,
        .finalizer = opts.finalizer,
        .run_at = milliTimestamp(.monotonic) + run_in_ms,
    });
}

// `deadline_ms` is an optional monotonic-clock deadline. When non-null, the
// scheduler returns after the currently-running task finishes if the clock
// has reached the deadline, leaving any still-ready tasks queued. The outer
// tick uses this to bound CDP message-handling latency on busy pages — see
// `Runner._tick` and the GitHub issue at lightpanda-io/browser#2402.
pub fn run(self: *Scheduler, deadline_ms: ?u64) !void {
    const now = milliTimestamp(.monotonic);
    try self.runQueue(&self.low_priority, now, deadline_ms);
    if (deadlineElapsed(deadline_ms)) return;
    try self.runQueue(&self.high_priority, now, deadline_ms);
}

pub fn hasReadyTasks(self: *Scheduler) bool {
    const now = milliTimestamp(.monotonic);
    return queueHasReadyTask(&self.low_priority, now) or queueHasReadyTask(&self.high_priority, now);
}

pub fn msToNextHigh(self: *Scheduler) ?u64 {
    const task = self.high_priority.peek() orelse return null;
    const now = milliTimestamp(.monotonic);
    if (task.run_at <= now) {
        return 0;
    }
    return @intCast(task.run_at - now);
}

fn runQueue(self: *Scheduler, queue: *Queue, now: u64, deadline_ms: ?u64) !void {
    if (queue.count() == 0) {
        return;
    }

    while (queue.peek()) |*task_| {
        if (task_.run_at > now) {
            return;
        }
        var task = queue.remove();
        if (comptime IS_DEBUG) {
            log.debug(.scheduler, "scheduler.runTask", .{ .name = task.name });
        }

        const repeat_in_ms = task.callback(task.ctx) catch |err| {
            log.warn(.scheduler, "task.callback", .{ .name = task.name, .err = err });
            continue;
        };

        if (repeat_in_ms) |ms| {
            // Task cannot be repeated immediately, and they should know that
            if (comptime IS_DEBUG) {
                std.debug.assert(ms != 0);
            }
            task.run_at = now + ms;
            try self.low_priority.add(task);
        }

        if (deadlineElapsed(deadline_ms)) return;
    }
    return;
}

inline fn deadlineElapsed(deadline_ms: ?u64) bool {
    const d = deadline_ms orelse return false;
    return milliTimestamp(.monotonic) >= d;
}

fn queueHasReadyTask(queue: *Queue, now: u64) bool {
    const task = queue.peek() orelse return false;
    return task.run_at <= now;
}

fn finalizeTasks(queue: *Queue) void {
    var it = queue.iterator();
    while (it.next()) |t| {
        if (t.finalizer) |func| {
            func(t.ctx);
        }
    }
}

const Task = struct {
    run_at: u64,
    sequence: u64,
    ctx: *anyopaque,
    name: []const u8,
    callback: Callback,
    finalizer: ?Finalizer,
};

const Callback = *const fn (ctx: *anyopaque) anyerror!?u32;
const Finalizer = *const fn (ctx: *anyopaque) void;

const Counter = struct {
    n: u32 = 0,
    fn cb(ctx: *anyopaque) anyerror!?u32 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.n += 1;
        return null;
    }
};

test "Scheduler.run with no deadline drains all ready tasks" {
    // Scheduler.deinit doesn't free the underlying PriorityQueue storage
    // (the production code relies on an arena allocator), so use an arena
    // here too to avoid noise from the testing allocator's leak detector.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var sched = Scheduler.init(arena.allocator());
    defer sched.deinit();

    var counter: Counter = .{};
    for (0..50) |_| {
        try sched.add(&counter, Counter.cb, 0, .{});
    }

    try sched.run(null);
    try std.testing.expectEqual(@as(u32, 50), counter.n);
}

test "Scheduler.run with already-elapsed deadline yields after first task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var sched = Scheduler.init(arena.allocator());
    defer sched.deinit();

    var counter: Counter = .{};
    // Add to the queue Scheduler.run drains first so the inner loop has
    // something to do before the outer deadline check kicks in.
    for (0..50) |_| {
        try sched.add(&counter, Counter.cb, 0, .{ .low_priority = true });
    }

    // A deadline of 1 is in the past relative to the monotonic clock, so the
    // loop runs exactly one task (the post-callback check yields) and the
    // outer between-queues check then prevents the high_priority queue from
    // running.
    try sched.run(1);
    try std.testing.expectEqual(@as(u32, 1), counter.n);

    // Remaining tasks are still queued — re-running drains them when no
    // deadline is set.
    try sched.run(null);
    try std.testing.expectEqual(@as(u32, 50), counter.n);
}
