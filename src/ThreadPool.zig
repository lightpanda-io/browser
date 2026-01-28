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

const log = @import("log.zig");

const ThreadPool = @This();

allocator: Allocator,

active: u16,
shutdown: bool,
max_threads: u16,

lock: std.Thread.RwLock,
threads: std.DoublyLinkedList,

const Func = struct {
    ptr: *const fn (*anyopaque) void,
    args: []u8,
    alignment: std.mem.Alignment,

    fn init(allocator: Allocator, func: anytype, args: anytype) !Func {
        const Args = @TypeOf(args);
        const Wrapper = struct {
            fn call(ctx: *anyopaque) void {
                const a: *Args = @ptrCast(@alignCast(ctx));
                @call(.auto, func, a.*);
            }
        };

        const alignment: std.mem.Alignment = .of(Args);
        const size = @sizeOf(Args);

        if (size == 0) {
            return .{
                .ptr = Wrapper.call,
                .args = &.{},
                .alignment = alignment,
            };
        }

        const args_buf = try allocator.alignedAlloc(u8, alignment, size);

        const bytes: []const u8 = @ptrCast((&args)[0..1]);
        @memcpy(args_buf, bytes);

        return .{
            .ptr = Wrapper.call,
            .args = args_buf,
            .alignment = alignment,
        };
    }

    fn call(self: Func) void {
        self.ptr(@ptrCast(self.args.ptr));
    }

    fn free(self: Func, allocator: Allocator) void {
        if (self.args.len > 0) {
            allocator.rawFree(self.args, self.alignment, @returnAddress());
        }
    }
};

const Worker = struct {
    run_fn: Func,
    shutdown_fn: Func,
    pool: *ThreadPool,
    thread: std.Thread,
    node: std.DoublyLinkedList.Node,

    fn run(self: *Worker) void {
        self.run_fn.call();
        self.deinit();
    }

    fn deinit(self: *Worker) void {
        const pool = self.pool;

        pool.lock.lock();
        pool.threads.remove(&self.node);
        pool.active -= 1;
        pool.lock.unlock();

        self.run_fn.free(pool.allocator);
        self.shutdown_fn.free(pool.allocator);
        pool.allocator.destroy(self);
    }

    fn callShutdown(self: *Worker) void {
        self.shutdown_fn.call();
    }
};

pub fn init(allocator: Allocator, max_threads: u16) ThreadPool {
    return .{
        .allocator = allocator,
        .max_threads = max_threads,
        .active = 0,
        .shutdown = false,
        .threads = .{},
        .lock = .{},
    };
}

pub fn deinit(self: *ThreadPool) void {
    self.join();
}

/// Spawn a thread to run run_func(run_args). shutdown_func is called during join().
pub fn spawn(
    self: *ThreadPool,
    run_func: anytype,
    run_args: std.meta.ArgsTuple(@TypeOf(run_func)),
    shutdown_func: anytype,
    shutdown_args: std.meta.ArgsTuple(@TypeOf(shutdown_func)),
) !void {
    const run_fn = try Func.init(self.allocator, run_func, run_args);
    errdefer run_fn.free(self.allocator);

    const shutdown_fn = try Func.init(self.allocator, shutdown_func, shutdown_args);
    errdefer shutdown_fn.free(self.allocator);

    const worker = try self.allocator.create(Worker);
    errdefer self.allocator.destroy(worker);

    worker.* = .{
        .run_fn = run_fn,
        .shutdown_fn = shutdown_fn,
        .pool = self,
        .thread = undefined,
        .node = .{},
    };

    self.lock.lock();
    defer self.lock.unlock();

    if (self.shutdown) {
        return error.PoolShuttingDown;
    }

    if (self.active >= self.max_threads) {
        return error.MaxThreadsReached;
    }

    self.threads.append(&worker.node);
    self.active += 1;

    worker.thread = std.Thread.spawn(.{}, Worker.run, .{worker}) catch |err| {
        self.threads.remove(&worker.node);
        self.active -= 1;
        return err;
    };
}

/// Number of active threads.
pub fn count(self: *ThreadPool) u16 {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.active;
}

/// Wait for all threads to finish.
pub fn join(self: *ThreadPool) void {
    self.lock.lock();
    self.shutdown = true;

    // Call shutdown on all active workers
    var node = self.threads.first;
    while (node) |n| {
        const worker: *Worker = @fieldParentPtr("node", n);
        worker.callShutdown();
        node = n.next;
    }
    self.lock.unlock();

    while (true) {
        self.lock.lockShared();
        const active = self.active;
        self.lock.unlockShared();

        if (active == 0) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

pub fn isShuttingDown(self: *ThreadPool) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.shutdown;
}

// Tests
const testing = std.testing;

fn noop() void {}

fn increment(counter: *std.atomic.Value(u32)) void {
    _ = counter.fetchAdd(1, .acq_rel);
}

fn block(flag: *std.atomic.Value(bool)) void {
    while (!flag.load(.acquire)) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

fn unblock(flag: *std.atomic.Value(bool)) void {
    flag.store(true, .release);
}

test "ThreadPool: spawn and join" {
    var counter = std.atomic.Value(u32).init(0);
    var pool = ThreadPool.init(testing.allocator, 4);
    defer pool.deinit();

    try pool.spawn(increment, .{&counter}, noop, .{});
    try pool.spawn(increment, .{&counter}, noop, .{});
    try pool.spawn(increment, .{&counter}, noop, .{});

    pool.join();

    try testing.expectEqual(@as(u32, 3), counter.load(.acquire));
    try testing.expectEqual(@as(u16, 0), pool.count());
}

test "ThreadPool: max threads limit" {
    var flag = std.atomic.Value(bool).init(false);
    var pool = ThreadPool.init(testing.allocator, 2);
    defer pool.deinit();

    try pool.spawn(block, .{&flag}, unblock, .{&flag});
    try pool.spawn(block, .{&flag}, unblock, .{&flag});

    try testing.expectError(error.MaxThreadsReached, pool.spawn(block, .{&flag}, unblock, .{&flag}));
    try testing.expectEqual(@as(u16, 2), pool.count());

    // deinit will call unblock via shutdown callback
}
