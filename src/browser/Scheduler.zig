// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("js/js.zig");
const log = @import("../log.zig");
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

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

const AddOpts = struct {
    name: []const u8 = "",
    low_priority: bool = false,
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
        .run_at = milliTimestamp(.monotonic) + run_in_ms,
    });
}

pub fn run(self: *Scheduler) !?u64 {
    _ = try self.runQueue(&self.low_priority);
    return self.runQueue(&self.high_priority);
}

fn runQueue(self: *Scheduler, queue: *Queue) !?u64 {
    if (queue.count() == 0) {
        return null;
    }

    const now = milliTimestamp(.monotonic);

    while (queue.peek()) |*task_| {
        if (task_.run_at > now) {
            return @intCast(task_.run_at - now);
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
            std.debug.assert(ms != 0);
            task.run_at = now + ms;
            try self.low_priority.add(task);
        }
    }
    return null;
}

const Task = struct {
    run_at: u64,
    sequence: u64,
    ctx: *anyopaque,
    name: []const u8,
    callback: Callback,
};

const Callback = *const fn (ctx: *anyopaque) anyerror!?u32;
