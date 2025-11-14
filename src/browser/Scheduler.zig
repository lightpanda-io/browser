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

const log = @import("../log.zig");
const timestamp = @import("../datetime.zig").milliTimestamp;

const IS_DEBUG = builtin.mode == .Debug;

const Queue = std.PriorityQueue(Task, void, struct {
    fn compare(_: void, a: Task, b: Task) std.math.Order {
        return std.math.order(a.run_at, b.run_at);
    }
}.compare);

const Scheduler = @This();

low_priority: Queue,
high_priority: Queue,

pub fn init(allocator: std.mem.Allocator) Scheduler {
    return .{
        .low_priority = Queue.init(allocator, {}),
        .high_priority = Queue.init(allocator, {}),
    };
}

pub fn reset(self: *Scheduler) void {
    self.low_priority.cap = 0;
    self.low_priority.items.len = 0;

    self.high_priority.cap = 0;
    self.high_priority.items.len = 0;
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
    return queue.add(.{
        .ctx = ctx,
        .callback = cb,
        .name = opts.name,
        .run_at = timestamp(.monotonic) + run_in_ms,
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

    const now = timestamp(.monotonic);

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
    ctx: *anyopaque,
    name: []const u8,
    callback: Callback,
};

const Callback = *const fn (ctx: *anyopaque) anyerror!?u32;
