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
allocator: std.mem.Allocator,
// Some things (e.g. IndexedDB) can have operations that are only valid for a
// specific task boundary. So every time we start a task, we increment the
// scheduler's generation. Code can snapshot this version and then compare it
// later to see if we're still in the same task.
generation: u64,
low_priority: Queue,
high_priority: Queue,

pub fn init(allocator: std.mem.Allocator) Scheduler {
    return .{
        ._sequence = 0,
        .allocator = allocator,
        .generation = 0,
        .low_priority = Queue.initContext({}),
        .high_priority = Queue.initContext({}),
    };
}

pub fn deinit(self: *Scheduler) void {
    finalizeTasks(&self.low_priority);
    finalizeTasks(&self.high_priority);
}

pub fn reset(self: *Scheduler) void {
    finalizeTasks(&self.low_priority);
    finalizeTasks(&self.high_priority);
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
    return queue.push(self.allocator, .{
        .ctx = ctx,
        .callback = cb,
        .sequence = seq,
        .name = opts.name,
        .finalizer = opts.finalizer,
        .run_at = milliTimestamp(.monotonic) + run_in_ms,
    });
}

pub fn run(self: *Scheduler) !void {
    try self.runQueue(&self.low_priority);
    try self.runQueue(&self.high_priority);
}

pub fn hasReadyTasks(self: *Scheduler) bool {
    const now = milliTimestamp(.monotonic);
    return queueHasReadyTask(&self.low_priority, now) or queueHasReadyTask(&self.high_priority, now);
}

pub fn msToNext(self: *Scheduler) ?u64 {
    var next: ?u64 = null;
    const now = milliTimestamp(.monotonic);
    for ([_]*Queue{ &self.high_priority, &self.low_priority }) |queue| {
        const task = queue.peek() orelse continue;
        const ms = if (task.run_at <= now) 0 else task.run_at - now;
        if (next == null or ms < next.?) {
            next = ms;
        }
    }
    return next;
}

fn runQueue(self: *Scheduler, queue: *Queue) !void {
    if (queue.count() == 0) {
        return;
    }
    const start = milliTimestamp(.monotonic);
    var now = start;

    while (queue.peek()) |*task_| {
        if (task_.run_at > now) {
            return;
        }
        var task = queue.pop().?;
        if (comptime IS_DEBUG) {
            log.debug(.scheduler, "scheduler.runTask", .{ .name = task.name });
        }

        self.generation +%= 1;

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
            try self.low_priority.push(self.allocator, task);
        }

        now = milliTimestamp(.monotonic);
        if (now - start > 500) {
            return;
        }
    }
    return;
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
