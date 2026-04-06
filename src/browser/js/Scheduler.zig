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
const builtin = @import("builtin");
const testing = std.testing;

const log = @import("../../log.zig");
const milliTimestamp = @import("../../datetime.zig").milliTimestamp;

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
    self.low_priority.deinit();
    self.high_priority.deinit();
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

pub fn run(self: *Scheduler) !?u64 {
    const low_next = try self.runQueue(&self.low_priority);
    const high_next = try self.runQueue(&self.high_priority);
    if (low_next == null) {
        return high_next;
    }
    if (high_next == null) {
        return low_next;
    }
    return @min(low_next.?, high_next.?);
}

pub fn hasReadyTasks(self: *Scheduler) bool {
    const now = milliTimestamp(.monotonic);
    return queueuHasReadyTask(&self.low_priority, now) or queueuHasReadyTask(&self.high_priority, now);
}

fn runQueue(self: *Scheduler, queue: *Queue) !?u64 {
    if (queue.count() == 0) {
        return null;
    }

    const now = milliTimestamp(.monotonic);
    const task_ = queue.peek() orelse return null;
    if (task_.run_at > now) {
        return @intCast(task_.run_at - now);
    }
    var task = queue.remove();
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "scheduler.runTask", .{ .name = task.name });
    }

    const repeat_in_ms = task.callback(task.ctx) catch |err| {
        log.warn(.scheduler, "task.callback", .{ .name = task.name, .err = err });
        return nextDelay(queue);
    };

    if (repeat_in_ms) |ms| {
        // Task cannot be repeated immediately, and they should know that
        if (comptime IS_DEBUG) {
            std.debug.assert(ms != 0);
        }
        task.run_at = now + ms;
        try self.low_priority.add(task);
    }

    return nextDelay(queue);
}

fn nextDelay(queue: *Queue) ?u64 {
    const next = queue.peek() orelse return null;
    const now = milliTimestamp(.monotonic);
    if (next.run_at <= now) {
        return 0;
    }
    return @intCast(next.run_at - now);
}

fn queueuHasReadyTask(queue: *Queue, now: u64) bool {
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

test "scheduler run yields after one ready task from a queue" {
    var scheduler = Scheduler.init(testing.allocator);
    defer scheduler.deinit();

    var count: usize = 0;

    const CallbackHarness = struct {
        fn run(ctx: *anyopaque) !?u32 {
            const counter: *usize = @ptrCast(@alignCast(ctx));
            counter.* += 1;
            return null;
        }
    };

    try scheduler.add(&count, CallbackHarness.run, 0, .{ .name = "first" });
    try scheduler.add(&count, CallbackHarness.run, 0, .{ .name = "second" });

    const first_next = try scheduler.run();
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(?u64, 0), first_next);

    const second_next = try scheduler.run();
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(?u64, null), second_next);
}

test "scheduler run reports low-priority delay when high queue is empty" {
    var scheduler = Scheduler.init(testing.allocator);
    defer scheduler.deinit();

    var count: usize = 0;

    const CallbackHarness = struct {
        fn run(ctx: *anyopaque) !?u32 {
            const counter: *usize = @ptrCast(@alignCast(ctx));
            counter.* += 1;
            return null;
        }
    };

    try scheduler.add(&count, CallbackHarness.run, 25, .{
        .name = "low-later",
        .low_priority = true,
    });

    const next = try scheduler.run();
    try testing.expectEqual(@as(usize, 0), count);
    try testing.expect(next != null);
    try testing.expect(next.? <= 25);
}
