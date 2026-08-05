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

const log = lp.log;
const Allocator = std.mem.Allocator;

// low bits of a Task.key hold the FIFO sequence; the high 40 hold run_at
// (~34 years of process uptime).
const SEQ_BITS = 24;
const SEQ_MASK = (@as(u64, 1) << SEQ_BITS) - 1;

const Scheduler = @This();

_sequence: u64,
allocator: Allocator,

// Tasks queued to be run at a specific time
timed: Queue,

// Tasks queued to be run at the next (optimization for when .run_at = 0)
immediate: Immediate,

// Tasks queued to run before anything else (i.e. scheduler.yield)
front: Immediate,

// Some things (e.g. IndexedDB) can have operations that are only valid for a
// specific task boundary. So every time we start a task, we increment the
// scheduler's generation. Code can snapshot this version and then compare it
// later to see if we're still in the same task.
generation: u64,

// Number of pending tasks with blocks_done=true. While > 0, the page isn't
// considered done.
blocking: u32,

pub fn init(allocator: Allocator) Scheduler {
    return .{
        ._sequence = 0,
        .allocator = allocator,
        .generation = 0,
        .blocking = 0,
        .timed = Queue.initContext({}),
        .immediate = .{},
        .front = .{},
    };
}

pub fn deinit(self: *Scheduler) void {
    self.finalizeTasks();
}

pub fn reset(self: *Scheduler) void {
    self.finalizeTasks();
    self.blocking = 0;
    self.front.clear();
    self.immediate.clear();
    self.timed.clearRetainingCapacity();
}

const AddOpts = struct {
    name: []const u8 = "",
    front: bool = false, // run before any other tasks, multi-fronts are FIFO amongst themselves
    blocks_done: bool = true,
    finalizer: ?Finalizer = null,
};
pub fn add(self: *Scheduler, ctx: *anyopaque, cb: Callback, run_in_ms: u32, opts: AddOpts) !void {
    if (comptime lp.IS_DEBUG) {
        log.debug(.scheduler, "scheduler.add", .{ .name = opts.name, .run_in_ms = run_in_ms, .blocks_done = opts.blocks_done });
    }
    if (comptime lp.IS_DEBUG) {
        // run_in_ms is ignored when opts.front == true, but let's enforce this
        // so that a caller isn't expecting something we don't support
        std.debug.assert(opts.front == false or run_in_ms == 0);
    }

    const run_at = lp.datetime.milliTimestamp(.boot) + run_in_ms;
    const task: Task = .{
        .ctx = ctx,
        .callback = cb,
        .name = opts.name,
        .key = self.nextKey(run_at),
        .finalizer = opts.finalizer,
        .blocks_done = opts.blocks_done,
    };

    if (opts.front) {
        try self.front.push(self.allocator, task);
    } else if (run_in_ms == 0) {
        try self.immediate.push(self.allocator, task);
    } else {
        try self.timed.push(self.allocator, task);
    }

    if (opts.blocks_done) {
        self.blocking += 1;
    }
}

pub fn run(self: *Scheduler) !void {
    const start = lp.datetime.milliTimestamp(.boot);
    var now = start;

    while (self.popReady(now)) |task_| {
        var task = task_;
        if (comptime lp.IS_DEBUG) {
            log.debug(.scheduler, "scheduler.runTask", .{ .name = task.name });
        }

        self.generation +%= 1;

        const repeat_in_ms = task.callback(task.ctx) catch |err| {
            log.warn(.scheduler, "task.callback", .{ .name = task.name, .err = err });
            continue;
        };

        if (repeat_in_ms) |ms| {
            // Task cannot be repeated immediately, and they should know that
            if (comptime lp.IS_DEBUG) {
                std.debug.assert(ms != 0);
            }
            // A task that endlessly reschedules itself would keep the page
            // alive forever, so repeats never block completion.
            task.blocks_done = false;
            task.key = self.nextKey(now + ms);
            try self.timed.push(self.allocator, task);
        }

        now = lp.datetime.milliTimestamp(.boot);
        if (now - start > 500) {
            return;
        }
    }
}

pub fn hasReadyTasks(self: *Scheduler) bool {
    const ms = self.msToNext() orelse return false;
    return ms == 0;
}

pub fn blocksCompletion(self: *const Scheduler) bool {
    return self.blocking > 0;
}

pub fn msToNext(self: *Scheduler) ?u64 {
    if (self.immediate.peek() != null or self.front.peek() != null) {
        return 0;
    }
    const task = self.timed.peek() orelse return null;
    const run_at = task.runAt();
    const now = lp.datetime.milliTimestamp(.boot);
    return if (run_at <= now) 0 else run_at - now;
}

fn nextKey(self: *Scheduler, run_at: u64) u64 {
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(run_at >> (64 - SEQ_BITS) == 0);
    }
    self._sequence +%= 1;
    return (run_at << SEQ_BITS) | (self._sequence & SEQ_MASK);
}

fn popReady(self: *Scheduler, now: u64) ?Task {
    const task = task: {
        if (self.front.peek() != null) {
            break :task self.front.pop();
        }

        const immediate = self.immediate.peek();
        const timed = self.timed.peek();

        const pick_immediate = if (immediate == null)
            false
        else if (timed == null)
            true
        else
            immediate.?.key < timed.?.key;

        if (pick_immediate) {
            break :task self.immediate.pop();
        }

        const candidate = timed orelse return null;
        if (candidate.runAt() > now) {
            return null;
        }

        break :task self.timed.pop().?;
    };

    if (task.blocks_done) {
        self.blocking -= 1;
    }
    return task;
}

fn finalizeTasks(self: *Scheduler) void {
    for (self.front.pending()) |task| {
        if (task.finalizer) |func| {
            func(task.ctx);
        }
    }
    for (self.immediate.pending()) |task| {
        if (task.finalizer) |func| {
            func(task.ctx);
        }
    }
    var it = self.timed.iterator();
    while (it.next()) |t| {
        if (t.finalizer) |func| {
            func(t.ctx);
        }
    }
}

const Task = struct {
    key: u64, // (run_at << SEQ_BITS) | sequence — tasks execute in key order
    ctx: *anyopaque,
    name: []const u8,
    blocks_done: bool,
    callback: Callback,
    finalizer: ?Finalizer,

    fn runAt(self: Task) u64 {
        return self.key >> SEQ_BITS;
    }
};

const Queue = std.PriorityQueue(Task, void, struct {
    fn compare(_: void, a: Task, b: Task) std.math.Order {
        return std.math.order(a.key, b.key);
    }
}.compare);

// FIFO for 0-delay and front tasks. They dominate real pages and this avoids
// the PriorityQueue sorting.
const Immediate = struct {
    head: usize = 0,
    tasks: std.ArrayList(Task) = .empty,

    fn push(self: *Immediate, allocator: Allocator, task: Task) !void {
        // pop can only reset tasks when its fully drained (which might not
        // be possible to do per-run in our 500ms budget). To prevent timer loop
        // from preventing the cleanup from ever happening, we compact on push
        // once we have enough entries to justify it (16 is arbitrarily chosen).
        const head = self.head;
        const live = self.tasks.items.len - head;
        if (head > 16 and head >= live) {
            std.mem.copyForwards(Task, self.tasks.items[0..live], self.tasks.items[head..]);
            self.tasks.shrinkRetainingCapacity(live);
            self.head = 0;
        }
        return self.tasks.append(allocator, task);
    }

    fn peek(self: *const Immediate) ?Task {
        if (self.head == self.tasks.items.len) {
            return null;
        }
        return self.tasks.items[self.head];
    }

    fn pop(self: *Immediate) Task {
        const task = self.tasks.items[self.head];
        self.head += 1;
        if (self.head == self.tasks.items.len) {
            self.clear();
        }
        return task;
    }

    fn pending(self: *const Immediate) []Task {
        return self.tasks.items[self.head..];
    }

    fn clear(self: *Immediate) void {
        self.head = 0;
        self.tasks.clearRetainingCapacity();
    }
};

const Callback = *const fn (ctx: *anyopaque) anyerror!?u32;
const Finalizer = *const fn (ctx: *anyopaque) void;

const testing = @import("../../testing.zig");
test "Scheduler: immediates are FIFO, front runs first" {
    var s = Scheduler.init(testing.arena_allocator);
    var ran: std.ArrayList(u8) = .empty;
    var t1: TestTask = .{ .id = 1, .ran = &ran };
    var t2: TestTask = .{ .id = 2, .ran = &ran };
    var t3: TestTask = .{ .id = 3, .ran = &ran };
    var t4: TestTask = .{ .id = 4, .ran = &ran };

    try s.add(&t1, TestTask.run, 0, .{});
    try s.add(&t2, TestTask.run, 0, .{});
    try s.add(&t3, TestTask.run, 0, .{ .front = true });
    try s.add(&t4, TestTask.run, 0, .{ .front = true });
    try s.run();
    try testing.expectEqualSlices(u8, &.{ 3, 4, 1, 2 }, ran.items);
}

test "Scheduler: due timed tasks run before newer immediates" {
    var s = Scheduler.init(testing.arena_allocator);
    var ran: std.ArrayList(u8) = .empty;
    var t1: TestTask = .{ .id = 1, .ran = &ran };
    var t2: TestTask = .{ .id = 2, .ran = &ran };

    try s.add(&t1, TestTask.run, 1, .{});
    lp.io.sleep(.fromMilliseconds(5), .awake) catch {};
    try s.add(&t2, TestTask.run, 0, .{});
    try s.run();
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, ran.items);
}

test "Scheduler: blocksCompletion" {
    var s = Scheduler.init(testing.arena_allocator);
    var ran: std.ArrayList(u8) = .empty;
    var t1: TestTask = .{ .id = 1, .ran = &ran, .repeat = 20 };
    var t2: TestTask = .{ .id = 2, .ran = &ran };

    try testing.expectEqual(false, s.blocksCompletion());
    try s.add(&t1, TestTask.run, 0, .{});
    try s.add(&t2, TestTask.run, 0, .{ .blocks_done = false });
    try testing.expectEqual(true, s.blocksCompletion());

    try s.run();
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, ran.items);
    // t1 was re-queued 20ms out, but repeats don't block completion
    try testing.expectEqual(1, s.timed.count());
    try testing.expectEqual(false, s.blocksCompletion());
}

test "Scheduler: immediate queue reclaims consumed prefix" {
    var im: Immediate = .{};
    const dummy: Task = .{
        .key = 0,
        .name = "",
        .ctx = undefined,
        .finalizer = null,
        .blocks_done = false,
        .callback = undefined,
    };

    // keep 2 tasks live at all times so pop never fully drains
    try im.push(testing.arena_allocator, dummy);
    try im.push(testing.arena_allocator, dummy);
    for (0..10_000) |_| {
        _ = im.pop();
        try im.push(testing.arena_allocator, dummy);
    }
    try testing.expect(im.tasks.items.len <= 64);
}

const TestTask = struct {
    id: u8,
    ran: *std.ArrayList(u8),
    repeat: ?u32 = null,

    fn run(ptr: *anyopaque) anyerror!?u32 {
        const self: *TestTask = @ptrCast(@alignCast(ptr));
        try self.ran.append(testing.arena_allocator, self.id);
        defer self.repeat = null;
        return self.repeat;
    }
};
