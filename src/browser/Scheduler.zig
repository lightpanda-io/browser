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

const lp = @import("lightpanda");

const Page = @import("Page.zig");

const log = @import("../log.zig");
const milliTimestamp = @import("../datetime.zig").milliTimestamp;
const heap = @import("../heap.zig");

const IS_DEBUG = builtin.mode == .Debug;

const Scheduler = @This();
high_priority: Task.Heap,
low_priority: Task.Heap,
task_pool: std.heap.MemoryPool(Task),

pub fn init(allocator: std.mem.Allocator) Scheduler {
    return .{
        .task_pool = .init(allocator),
        .high_priority = .{ .context = {} },
        .low_priority = .{ .context = {} },
    };
}

pub fn deinit(self: *Scheduler) void {
    self.task_pool.deinit();
}

pub const Priority = enum(u1) { low, high };

pub const ScheduleOptions = struct {
    name: []const u8 = "unspecified",
    priority: Priority = .high,
    // TODO: Backport finalizer.
};

/// Schedules a task; runs it once.
pub fn once(
    self: *Scheduler,
    comptime options: ScheduleOptions,
    /// Type of `ctx`.
    comptime T: type,
    ctx: *T,
    comptime callback: *const fn (scheduler: *Scheduler, ctx: *T) anyerror!void,
) !void {
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "Scheduler.once", .{ .name = options.name, .priority = @tagName(options.priority) });
    }

    const runner = struct {
        fn runner(task: *Task, scheduler: *Scheduler) void {
            // Give type-erased ctx a type.
            const typed_ctx: *T = @ptrCast(@alignCast(task.ctx));

            // Run provided callback; this can fail, we'll ignore it though.
            @call(.auto, callback, .{ scheduler, typed_ctx }) catch |err| {
                log.warn(.scheduler, "Task.callback", .{
                    .name = options.name,
                    .priority = @tagName(options.priority),
                    .err = err,
                });
            };

            // Return task back to pool.
            scheduler.task_pool.destroy(task);
        }
    }.runner;

    const task = try self.task_pool.create();
    task.* = .{
        // This variant always have 0-timeout.
        .run_at = milliTimestamp(.monotonic),
        .ctx = ctx,
        .callback = runner,
    };

    // Push to right heap.
    switch (options.priority) {
        .low => self.low_priority.insert(task),
        .high => self.high_priority.insert(task),
    }
}

/// Action to be taken `after` callback being run.
/// Don't manually create this, prefer such syntax:
///
/// ```zig
/// .repeat(150); // Repeat after 150ms.
/// .dont_repeat; // Don't repeat.
/// ```
pub const AfterAction = packed struct(u32) {
    /// Whether rerun.
    recur: bool,
    /// Largest repeat `setInterval` can have is 2147483647ms.
    ms: u31,

    pub const dont_repeat = AfterAction{ .recur = false, .ms = 0 };

    pub inline fn repeat(ms: u31) AfterAction {
        return .{ .recur = true, .ms = ms };
    }
};

/// Schedules a task that'll be run after given time in ms.
pub fn after(
    self: *Scheduler,
    comptime options: ScheduleOptions,
    /// Type of `ctx`.
    comptime T: type,
    ctx: *T,
    run_in_ms: u32,
    /// If an integer is returned, the task will be repeated after that much ms.
    /// If null is returned, task won't be repeated.
    comptime callback: *const fn (scheduler: *Scheduler, ctx: *T) anyerror!AfterAction,
) !void {
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "Scheduler.after", .{
            .name = options.name,
            .run_in_ms = run_in_ms,
            .priority = @tagName(options.priority),
        });
    }

    const runner = struct {
        fn runner(task: *Task, scheduler: *Scheduler) void {
            // Give type-erased ctx a type.
            const typed_ctx: *T = @ptrCast(@alignCast(task.ctx));

            // Run provided callback; this can fail, we'll ignore it though.
            const result = @call(.auto, callback, .{ scheduler, typed_ctx }) catch |err| {
                log.warn(.scheduler, "Task.callback", .{
                    .name = options.name,
                    .priority = @tagName(options.priority),
                    .err = err,
                });

                // Can't repeat w/o return value.
                scheduler.task_pool.destroy(task);
                return;
            };

            // If task is not repeated, disarm.
            if (!result.recur) {
                scheduler.task_pool.destroy(task);
                return;
            }

            // Wants recur.
            const repeat_in_ms = result.ms;
            // Task cannot be repeated immediately, and they should know that.
            lp.assert(repeat_in_ms != 0, "Task.callback: 0-timer", .{ .name = options.name });
            task.run_at = milliTimestamp(.monotonic) + repeat_in_ms;
            // Prefer low priority?
            scheduler.low_priority.insert(task);
        }
    }.runner;

    const task = try self.task_pool.create();
    task.* = .{
        .run_at = milliTimestamp(.monotonic) + run_in_ms,
        .ctx = ctx,
        .callback = runner,
    };

    // Push to right heap.
    switch (options.priority) {
        .low => self.low_priority.insert(task),
        .high => self.high_priority.insert(task),
    }
}

pub fn run(self: *Scheduler) !?u64 {
    self.runTasks(.low);
    return self.runTasks(.high);
}

/// Runs events of the desired tree.
fn runTasks(self: *Scheduler, comptime prio: Priority) if (prio == .low) void else ?u64 {
    const tree = if (comptime prio == .low) &self.low_priority else &self.high_priority;

    // const cached_time = self.cached_time;
    // const now = milliTimestamp(.monotonic);
    // Update cache...
    // self.cached_time = now;

    const now = milliTimestamp(.monotonic);

    while (tree.peek()) |task| {
        // No tasks to execute so far.
        if (task.run_at > now) {
            if (comptime prio == .low) {
                break;
            }

            return task.run_at - now;
        }

        // Remove from the heap.
        const min = tree.deleteMin();
        lp.assert(min.? == task, "Scheduler.runTasks: unexpected", .{});

        if (comptime IS_DEBUG) {
            log.debug(.scheduler, "Scheduler.runTasks", .{ .prio = @tagName(prio) });
        }

        task.callback(task, self);
    }

    if (comptime prio == .high) {
        return null;
    }
}

/// Internal task representation.
const Task = struct {
    /// When to execute this task.
    run_at: u64,
    /// Userdata.
    ctx: *anyopaque,
    callback: *const fn (task: *Task, scheduler: *Scheduler) void,
    heap: heap.IntrusiveField(Task) = .{},

    const Heap = heap.Intrusive(Task, void, Task.less);

    /// Compare 2 tasks by their execution time.
    fn less(_: void, a: *const Task, b: *const Task) bool {
        return a.run_at < b.run_at;
    }
};
