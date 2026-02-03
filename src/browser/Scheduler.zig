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
    // Release memory pool after finalization.
    defer self.task_pool.deinit();

    // Finalize all low-prio tasks.
    while (self.low_priority.deleteMin()) |task| {
        if (task.on_finalize) |on_finalize| {
            @call(.auto, on_finalize, .{ task, self });
        }
    }

    // Finalize all high-prio tasks.
    while (self.high_priority.deleteMin()) |task| {
        if (task.on_finalize) |on_finalize| {
            @call(.auto, on_finalize, .{ task, self });
        }
    }
}

/// How to schedule a task 101:
///
/// If a task is being scheduled via `Scheduler.once`, the passed type must have
/// `action` callback implemented. Here's the function signature:
///
/// ```zig
/// pub fn action(scheduler: *Scheduler, context: *T) !void {
///     // ...
/// }
/// ```
///
/// If a task is being scheduled via `Scheduled.afer` instead, the passed type
/// must have `action` callback with this signature:
///
/// ```zig
/// pub fn action(scheduler: *Scheduler, context: *T) !AfterAction {
///     // ...
///
///     // Repeat this `action` after 200ms:
///     return .repeat(200);
///
///     // Don't repeat the action.
///     return .dont_repeat;
/// }
/// ```
///
/// Both variants can also have `finalize` callback:
///
/// ```zig
/// pub fn finalize(context: *T) void {
///     // ...
/// }
/// ```
///
/// The "finalizers" will be fired before `Scheduler` itself is deinitialized.
pub const ScheduleInterface = struct {};

pub const Priority = enum(u1) { low, high };

pub const ScheduleOptions = struct {
    name: []const u8 = "unspecified",
    prio: Priority,
};

/// Schedules a task that'll be executed in the next run.
pub fn once(
    self: *Scheduler,
    comptime options: ScheduleOptions,
    /// Type of `ctx`.
    comptime T: type,
    ctx: *T,
    /// See `Scheduler.ScheduleInterface` for reference.
    comptime Interface: anytype,
) !void {
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "Scheduler.once", .{ .name = options.name, .prio = @tagName(options.prio) });
    }

    const action_runner = struct {
        fn runner(task: *Task, scheduler: *Scheduler) void {
            // Return task back to pool once done.
            defer scheduler.task_pool.destroy(task);
            // Give type-erased ctx a type.
            const typed_ctx: *T = @ptrCast(@alignCast(task.ctx));

            // Run provided callback; this can fail, we won't handle it though.
            @call(.auto, Interface.action, .{ scheduler, typed_ctx }) catch |err| {
                log.warn(.scheduler, "Task.action", .{
                    .name = options.name,
                    .priority = @tagName(options.prio),
                    .err = err,
                });
            };
        }
    }.runner;

    // Finalizer, if provided.
    const finalize_runner = blk: {
        if (!std.meta.hasFn(Interface, "finalize")) {
            break :blk null;
        }

        break :blk (struct {
            fn runner(task: *Task, scheduler: *Scheduler) void {
                defer scheduler.task_pool.destroy(task);
                const typed_ctx: *T = @ptrCast(@alignCast(task.ctx));

                @call(.always_inline, Interface.finalize, .{typed_ctx});
            }
        }).runner;
    };

    const task = try self.task_pool.create();
    task.* = .{
        // This variant always have 0-timeout.
        .run_at = milliTimestamp(.monotonic),
        .ctx = ctx,
        .on_action = action_runner,
        .on_finalize = finalize_runner,
    };

    // Push to right heap.
    switch (options.prio) {
        .low => self.low_priority.insert(task),
        .high => self.high_priority.insert(task),
    }
}

/// Action to be taken after callback being run.
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
    /// See `Scheduler.ScheduleInterface` for reference.
    comptime Interface: anytype,
) !void {
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "Scheduler.after", .{
            .name = options.name,
            .run_in_ms = run_in_ms,
            .priority = @tagName(options.prio),
        });
    }

    const action_runner = struct {
        fn runner(task: *Task, scheduler: *Scheduler) void {
            // Give type-erased ctx a type.
            const typed_ctx: *T = @ptrCast(@alignCast(task.ctx));

            // Run provided callback; this can fail, we won't handle it though.
            const result = @call(.auto, Interface.action, .{ scheduler, typed_ctx }) catch |err| blk: {
                log.warn(.scheduler, "Task.action", .{
                    .name = options.name,
                    .priority = @tagName(options.prio),
                    .err = err,
                });

                // Can't repeat w/o return value.
                break :blk AfterAction.dont_repeat;
            };

            // If task is not repeated, disarm.
            if (!result.recur) {
                scheduler.task_pool.destroy(task);
                return;
            }

            // Wants recur.
            const repeat_in_ms = result.ms;
            // Task cannot be repeated immediately, and they should know that.
            lp.assert(repeat_in_ms != 0, "Task.action: 0-timer", .{ .name = options.name });
            task.run_at = milliTimestamp(.monotonic) + repeat_in_ms;
            // Prefer low priority?
            scheduler.low_priority.insert(task);
        }
    }.runner;

    // Finalizer, if provided.
    const finalize_runner = blk: {
        if (!std.meta.hasFn(Interface, "finalize")) {
            break :blk null;
        }

        break :blk (struct {
            fn runner(task: *Task, scheduler: *Scheduler) void {
                defer scheduler.task_pool.destroy(task);
                const typed_ctx: *T = @ptrCast(@alignCast(task.ctx));

                @call(.always_inline, Interface.finalize, .{typed_ctx});
            }
        }).runner;
    };

    const task = try self.task_pool.create();
    task.* = .{
        .run_at = milliTimestamp(.monotonic) + run_in_ms,
        .ctx = ctx,
        .on_action = action_runner,
        .on_finalize = finalize_runner,
    };

    // Push to right heap.
    switch (options.prio) {
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
    const now = milliTimestamp(.monotonic);
    const tree = if (comptime prio == .low) &self.low_priority else &self.high_priority;

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

        @call(.auto, task.on_action, .{ task, self });
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
    on_action: *const fn (task: *Task, scheduler: *Scheduler) void,
    on_finalize: ?*const fn (task: *Task, scheduler: *Scheduler) void = null,
    /// Entry in `Heap`.
    heap: heap.IntrusiveField(Task) = .{},

    const Heap = heap.Intrusive(Task, void, Task.less);

    /// Compare 2 tasks by their execution time.
    fn less(_: void, a: *const Task, b: *const Task) bool {
        return a.run_at < b.run_at;
    }
};
