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
const Allocator = std.mem.Allocator;

const Scheduler = @This();

high_priority: Queue,

// For repeating tasks. We only want to run these if there are other things to
// do. We don't, for example, want a window.setInterval or the page.runMicrotasks
// to block the page.wait.
low_priority: Queue,

// we expect allocator to be the page arena, hence we never call high_priority.deinit
pub fn init(allocator: Allocator) Scheduler {
    return .{
        .high_priority = Queue.init(allocator, {}),
        .low_priority = Queue.init(allocator, {}),
    };
}

pub fn reset(self: *Scheduler) void {
    self.high_priority.clearRetainingCapacity();
    self.low_priority.clearRetainingCapacity();
}

const AddOpts = struct {
    name: []const u8 = "",
    low_priority: bool = false,
};
pub fn add(self: *Scheduler, ctx: *anyopaque, func: Task.Func, ms: u32, opts: AddOpts) !void {
    var low_priority = opts.low_priority;
    if (ms > 5_000) {
        // we don't want tasks in the far future to block page.wait from
        // completing. However, if page.wait is called multiple times (maybe
        // a CDP driver is wait for something to happen), then we do want
        // to [eventually] run these when their time is up.
        low_priority = true;
    }

    var q = if (low_priority) &self.low_priority else &self.high_priority;
    return q.add(.{
        .ms = std.time.milliTimestamp() + ms,
        .ctx = ctx,
        .func = func,
        .name = opts.name,
    });
}

pub fn run(self: *Scheduler) !?i32 {
    _ = try self.runQueue(&self.low_priority);
    return self.runQueue(&self.high_priority);
}

fn runQueue(self: *Scheduler, queue: *Queue) !?i32 {
    // this is O(1)
    if (queue.count() == 0) {
        return null;
    }

    const now = std.time.milliTimestamp();

    var next = queue.peek();
    while (next) |task| {
        const time_to_next = task.ms - now;
        if (time_to_next > 0) {
            // @intCast is petty safe since we limit tasks to just 5 seconds
            // in the future
            return @intCast(time_to_next);
        }

        if (task.func(task.ctx)) |repeat_delay| {
            // if we do (now + 0) then our WHILE loop will run endlessly.
            // no task should ever return 0
            std.debug.assert(repeat_delay != 0);

            var copy = task;
            copy.ms = now + repeat_delay;
            try self.low_priority.add(copy);
        }
        _ = queue.remove();
        next = queue.peek();
    }
    return null;
}

const Task = struct {
    ms: i64,
    func: Func,
    ctx: *anyopaque,
    name: []const u8,

    const Func = *const fn (ctx: *anyopaque) ?u32;
};

const Queue = std.PriorityQueue(Task, void, struct {
    fn compare(_: void, a: Task, b: Task) std.math.Order {
        return std.math.order(a.ms, b.ms);
    }
}.compare);

const testing = @import("../testing.zig");
test "Scheduler" {
    defer testing.reset();

    var task = TestTask{ .allocator = testing.arena_allocator };

    var s = Scheduler.init(testing.arena_allocator);
    try testing.expectEqual(null, s.run());
    try testing.expectEqual(0, task.calls.items.len);

    try s.add(&task, TestTask.run1, 3, .{});

    try testing.expectDelta(3, try s.run(), 1);
    try testing.expectEqual(0, task.calls.items.len);

    std.Thread.sleep(std.time.ns_per_ms * 5);
    try testing.expectEqual(null, s.run());
    try testing.expectEqualSlices(u32, &.{1}, task.calls.items);

    try s.add(&task, TestTask.run2, 3, .{});
    try s.add(&task, TestTask.run1, 2, .{});

    std.Thread.sleep(std.time.ns_per_ms * 5);
    try testing.expectDelta(null, try s.run(), 1);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 2 }, task.calls.items);
}

const TestTask = struct {
    allocator: Allocator,
    calls: std.ArrayListUnmanaged(u32) = .{},

    fn run1(ctx: *anyopaque) ?u32 {
        var self: *TestTask = @ptrCast(@alignCast(ctx));
        self.calls.append(self.allocator, 1) catch unreachable;
        return null;
    }

    fn run2(ctx: *anyopaque) ?u32 {
        var self: *TestTask = @ptrCast(@alignCast(ctx));
        self.calls.append(self.allocator, 2) catch unreachable;
        return 2;
    }
};
