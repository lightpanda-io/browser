// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const MemoryPool = std.heap.MemoryPool;

const log = @import("../log.zig");
pub const IO = @import("tigerbeetle-io").IO;

const RUN_DURATION = 10 * std.time.ns_per_ms;

// SingleThreaded I/O Loop based on Tigerbeetle io_uring loop.
// On Linux it's using io_uring.
// On MacOS and Windows it's using kqueue/IOCP with a ring design.
// This is a thread-unsafe version without any lock on shared resources,
// use it only on a single thread.
// The loop provides I/O APIs based on callbacks.
// I/O APIs based on async/await might be added in the future.
pub const Loop = struct {
    alloc: std.mem.Allocator, // TODO: unmanaged version ?
    io: IO,

    // number of pending network events we have
    pending_network_count: usize,

    // number of pending timeout events we have
    pending_timeout_count: usize,

    // Used to stop repeating timeouts when loop.run is called.
    stopping: bool,

    // ctx_id is incremented each time the loop is reset.
    // All callbacks store an initial ctx_id and compare before execution.
    // If a ctx is outdated, the callback is ignored.
    // This is a weak way to cancel all future callbacks.
    ctx_id: u32 = 0,

    // We use this to track cancellation ids and, on the timeout callback,
    // we can can check here to see if it's been cancelled.
    cancelled: std.AutoHashMapUnmanaged(usize, void),

    timeout_pool: MemoryPool(ContextTimeout),
    event_callback_pool: MemoryPool(EventCallbackContext),

    const Self = @This();
    pub const Completion = IO.Completion;

    pub const RecvError = IO.RecvError;
    pub const SendError = IO.SendError;
    pub const ConnectError = IO.ConnectError;

    pub fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .alloc = alloc,
            .cancelled = .{},
            .io = try IO.init(32, 0),
            .stopping = false,
            .pending_network_count = 0,
            .pending_timeout_count = 0,
            .timeout_pool = MemoryPool(ContextTimeout).init(alloc),
            .event_callback_pool = MemoryPool(EventCallbackContext).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.reset();

        // run tail events. We do run the tail events to ensure all the
        // contexts are correcly free.
        while (self.pending_network_count != 0 or self.pending_timeout_count != 0) {
            self.io.run_for_ns(RUN_DURATION) catch |err| {
                log.err(.loop, "deinit", .{ .err = err });
                break;
            };
        }

        if (comptime CANCEL_SUPPORTED) {
            self.io.cancel_all();
        }
        self.io.deinit();
        self.timeout_pool.deinit();
        self.event_callback_pool.deinit();
        self.cancelled.deinit(self.alloc);
    }

    // Retrieve all registred I/O events completed by OS kernel,
    // and execute sequentially their callbacks.
    // Stops when there is no more I/O events registered on the loop.
    // Note that I/O events callbacks might register more I/O events
    // on the go when they are executed (ie. nested I/O events).
    pub fn run(self: *Self, wait_ns: usize) !void {
        // stop repeating / interval timeouts from re-registering
        self.stopping = true;
        defer self.stopping = false;

        const max_iterations = wait_ns / (RUN_DURATION);
        for (0..max_iterations) |_| {
            if (self.pending_network_count == 0 and self.pending_timeout_count == 0) {
                break;
            }
            self.io.run_for_ns(std.time.ns_per_ms * 10) catch |err| {
                log.err(.loop, "deinit", .{ .err = err });
                break;
            };
        }
    }

    // JS callbacks APIs
    // -----------------

    // Timeout

    // The state that we add to a timeout. This is what we get back from a
    // timeoutCallback. It contains the function to execute. The user is expected
    // to be able to turn a reference to this into whatever state it needs,
    // probably by inserting this node into its own stae and using @fieldParentPtr
    pub const CallbackNode = struct {
        func: *const fn (node: *CallbackNode, repeat: *?u63) void,
    };

    const ContextTimeout = struct {
        loop: *Self,
        ctx_id: u32,
        initial: bool = true,
        callback_node: ?*CallbackNode,
    };

    fn timeoutCallback(
        ctx: *ContextTimeout,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        var repeating = false;
        const loop = ctx.loop;

        if (ctx.initial) {
            loop.pending_timeout_count -= 1;
        }

        defer {
            if (repeating == false) {
                loop.timeout_pool.destroy(ctx);
                loop.alloc.destroy(completion);
            }
        }

        if (loop.cancelled.remove(@intFromPtr(completion))) {
            return;
        }

        // Abort if this completion was created for a different version of the loop.
        if (ctx.ctx_id != loop.ctx_id) {
            return;
        }

        // TODO: return the error to the callback
        result catch |err| {
            switch (err) {
                error.Canceled => {},
                else => log.err(.loop, "timeout callback error", .{ .err = err }),
            }
            return;
        };

        if (ctx.callback_node) |cn| {
            var repeat_in: ?u63 = null;
            cn.func(cn, &repeat_in);
            if (loop.stopping == false) {
                if (repeat_in) |r| {
                    // prevents our context and completion from being cleaned up
                    repeating = true;
                    ctx.initial = false;
                    loop.scheduleTimeout(r, ctx, completion);
                }
            }
        }
    }

    pub fn timeout(self: *Self, nanoseconds: u63, callback_node: ?*CallbackNode) !usize {
        const completion = try self.alloc.create(Completion);
        errdefer self.alloc.destroy(completion);
        completion.* = undefined;

        const ctx = try self.timeout_pool.create();
        errdefer self.timeout_pool.destroy(ctx);
        ctx.* = .{
            .loop = self,
            .ctx_id = self.ctx_id,
            .callback_node = callback_node,
        };

        self.pending_timeout_count += 1;
        self.scheduleTimeout(nanoseconds, ctx, completion);
        return @intFromPtr(completion);
    }

    fn scheduleTimeout(self: *Self, nanoseconds: u63, ctx: *ContextTimeout, completion: *Completion) void {
        self.io.timeout(*ContextTimeout, ctx, timeoutCallback, completion, nanoseconds);
    }

    pub fn cancel(self: *Self, id: usize) !void {
        try self.cancelled.put(self.alloc, id, {});
    }

    // Reset all existing callbacks.
    // The existing events will happen and their memory will be cleanup but the
    // corresponding callbacks will not be called.
    pub fn reset(self: *Self) void {
        self.ctx_id += 1;
        self.cancelled.clearRetainingCapacity();
    }

    // IO callbacks APIs
    // -----------------

    // Connect

    pub fn connect(
        self: *Self,
        comptime Ctx: type,
        ctx: *Ctx,
        completion: *Completion,
        comptime cbk: fn (ctx: *Ctx, _: *Completion, res: ConnectError!void) void,
        socket: std.posix.socket_t,
        address: std.net.Address,
    ) !void {
        const onConnect = struct {
            fn onConnect(callback: *EventCallbackContext, completion_: *Completion, res: ConnectError!void) void {
                callback.loop.pending_network_count -= 1;
                defer callback.loop.event_callback_pool.destroy(callback);
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onConnect;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.pending_network_count += 1;
        self.io.connect(*EventCallbackContext, callback, onConnect, completion, socket, address);
    }

    // Send

    pub fn send(
        self: *Self,
        comptime Ctx: type,
        ctx: *Ctx,
        completion: *Completion,
        comptime cbk: fn (ctx: *Ctx, completion: *Completion, res: SendError!usize) void,
        socket: std.posix.socket_t,
        buf: []const u8,
    ) !void {
        const onSend = struct {
            fn onSend(callback: *EventCallbackContext, completion_: *Completion, res: SendError!usize) void {
                callback.loop.pending_network_count -= 1;
                defer callback.loop.event_callback_pool.destroy(callback);
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onSend;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.pending_network_count += 1;
        self.io.send(*EventCallbackContext, callback, onSend, completion, socket, buf);
    }

    // Recv

    pub fn recv(
        self: *Self,
        comptime Ctx: type,
        ctx: *Ctx,
        completion: *Completion,
        comptime cbk: fn (ctx: *Ctx, completion: *Completion, res: RecvError!usize) void,
        socket: std.posix.socket_t,
        buf: []u8,
    ) !void {
        const onRecv = struct {
            fn onRecv(callback: *EventCallbackContext, completion_: *Completion, res: RecvError!usize) void {
                callback.loop.pending_network_count -= 1;
                defer callback.loop.event_callback_pool.destroy(callback);
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onRecv;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };
        self.pending_network_count += 1;
        self.io.recv(*EventCallbackContext, callback, onRecv, completion, socket, buf);
    }
};

const EventCallbackContext = struct {
    ctx: *anyopaque,
    loop: *Loop,
};

const CANCEL_SUPPORTED = switch (builtin.target.os.tag) {
    .linux => true,
    .macos, .tvos, .watchos, .ios => false,
    else => @compileError("IO is not supported for platform"),
};
