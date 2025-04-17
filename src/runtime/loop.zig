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

pub const IO = @import("tigerbeetle-io").IO;

const JSCallback = @import("../browser/env.zig").Env.Callback;

const log = std.log.scoped(.loop);

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

    // both events_nb are used to track how many callbacks are to be called.
    // We use these counters to wait until all the events are finished.
    js_events_nb: usize,
    zig_events_nb: usize,

    cbk_error: bool = false,

    // js_ctx_id is incremented each time the loop is reset for JS.
    // All JS callbacks store an initial js_ctx_id and compare before execution.
    // If a ctx is outdated, the callback is ignored.
    // This is a weak way to cancel all future JS callbacks.
    js_ctx_id: u32 = 0,

    // zig_ctx_id is incremented each time the loop is reset for Zig.
    // All Zig callbacks store an initial zig_ctx_id and compare before execution.
    // If a ctx is outdated, the callback is ignored.
    // This is a weak way to cancel all future Zig callbacks.
    zig_ctx_id: u32 = 0,

    // The MacOS event loop doesn't support cancellation. We use this to track
    // cancellation ids and, on the timeout callback, we can can check here
    // to see if it's been cancelled.
    cancelled: std.AutoHashMapUnmanaged(usize, void),

    cancel_pool: MemoryPool(ContextCancel),
    timeout_pool: MemoryPool(ContextTimeout),
    event_callback_pool: MemoryPool(EventCallbackContext),

    const Self = @This();
    pub const Completion = IO.Completion;

    pub const ConnectError = IO.ConnectError;
    pub const RecvError = IO.RecvError;
    pub const SendError = IO.SendError;

    pub fn init(alloc: std.mem.Allocator) !Self {
        return Self{
            .alloc = alloc,
            .cancelled = .{},
            .io = try IO.init(32, 0),
            .js_events_nb = 0,
            .zig_events_nb = 0,
            .cancel_pool = MemoryPool(ContextCancel).init(alloc),
            .timeout_pool = MemoryPool(ContextTimeout).init(alloc),
            .event_callback_pool = MemoryPool(EventCallbackContext).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        // first disable callbacks for existing events.
        // We don't want a callback re-create a setTimeout, it could create an
        // infinite loop on wait for events.
        self.resetJS();
        self.resetZig();

        // run tail events. We do run the tail events to ensure all the
        // contexts are correcly free.
        while (self.eventsNb(.js) > 0 or self.eventsNb(.zig) > 0) {
            self.io.run_for_ns(10 * std.time.ns_per_ms) catch |err| {
                log.err("deinit run tail events: {any}", .{err});
                break;
            };
        }
        if (comptime CANCEL_SUPPORTED) {
            self.io.cancel_all();
        }
        self.io.deinit();
        self.cancel_pool.deinit();
        self.timeout_pool.deinit();
        self.event_callback_pool.deinit();
        self.cancelled.deinit(self.alloc);
    }

    // Retrieve all registred I/O events completed by OS kernel,
    // and execute sequentially their callbacks.
    // Stops when there is no more I/O events registered on the loop.
    // Note that I/O events callbacks might register more I/O events
    // on the go when they are executed (ie. nested I/O events).
    pub fn run(self: *Self) !void {
        while (self.eventsNb(.js) > 0) {
            try self.io.run_for_ns(10 * std.time.ns_per_ms);
            // at each iteration we might have new events registred by previous callbacks
        }
        // TODO: return instead immediatly on the first JS callback error
        // and let the caller decide what to do next
        // (typically retrieve the exception through the TryCatch and
        // continue the execution of callbacks with a new call to loop.run)
        if (self.cbk_error) {
            return error.JSExecCallback;
        }
    }

    const Event = enum { js, zig };

    fn eventsPtr(self: *Self, comptime event: Event) *usize {
        return switch (event) {
            .zig => &self.zig_events_nb,
            .js => &self.js_events_nb,
        };
    }

    // Register events atomically
    // - add 1 event and return previous value
    fn addEvent(self: *Self, comptime event: Event) void {
        _ = @atomicRmw(usize, self.eventsPtr(event), .Add, 1, .acq_rel);
    }
    // - remove 1 event and return previous value
    fn removeEvent(self: *Self, comptime event: Event) void {
        _ = @atomicRmw(usize, self.eventsPtr(event), .Sub, 1, .acq_rel);
    }
    // - get the number of current events
    fn eventsNb(self: *Self, comptime event: Event) usize {
        return @atomicLoad(usize, self.eventsPtr(event), .seq_cst);
    }

    // JS callbacks APIs
    // -----------------

    // Timeout

    const ContextTimeout = struct {
        loop: *Self,
        js_cbk: ?JSCallback,
        js_ctx_id: u32,
    };

    fn timeoutCallback(
        ctx: *ContextTimeout,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        const loop = ctx.loop;
        defer {
            loop.removeEvent(.js);
            loop.timeout_pool.destroy(ctx);
            loop.alloc.destroy(completion);
        }

        if (comptime CANCEL_SUPPORTED == false) {
            if (loop.cancelled.remove(@intFromPtr(completion))) {
                return;
            }
        }

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.js_ctx_id != loop.js_ctx_id) return;

        // TODO: return the error to the callback
        result catch |err| {
            switch (err) {
                error.Canceled => {},
                else => log.err("timeout callback: {any}", .{err}),
            }
            return;
        };

        // js callback
        if (ctx.js_cbk) |*js_cbk| {
            js_cbk.call(null) catch {
                loop.cbk_error = true;
            };
        }
    }

    pub fn timeout(self: *Self, nanoseconds: u63, js_cbk: ?JSCallback) !usize {
        const completion = try self.alloc.create(Completion);
        errdefer self.alloc.destroy(completion);
        completion.* = undefined;

        const ctx = try self.timeout_pool.create();
        errdefer self.timeout_pool.destroy(ctx);
        ctx.* = ContextTimeout{
            .loop = self,
            .js_cbk = js_cbk,
            .js_ctx_id = self.js_ctx_id,
        };

        self.addEvent(.js);
        self.io.timeout(*ContextTimeout, ctx, timeoutCallback, completion, nanoseconds);
        return @intFromPtr(completion);
    }

    const ContextCancel = struct {
        loop: *Self,
        js_cbk: ?JSCallback,
        js_ctx_id: u32,
    };

    fn cancelCallback(
        ctx: *ContextCancel,
        completion: *IO.Completion,
        result: IO.CancelOneError!void,
    ) void {
        const loop = ctx.loop;

        defer {
            loop.removeEvent(.js);
            loop.cancel_pool.destroy(ctx);
            loop.alloc.destroy(completion);
        }

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.js_ctx_id != loop.js_ctx_id) return;

        // TODO: return the error to the callback
        result catch |err| {
            switch (err) {
                error.NotFound => log.debug("cancel callback: {any}", .{err}),
                else => log.err("cancel callback: {any}", .{err}),
            }
            return;
        };

        // js callback
        if (ctx.js_cbk) |*js_cbk| {
            js_cbk.call(null) catch {
                loop.cbk_error = true;
            };
        }
    }

    pub fn cancel(self: *Self, id: usize, js_cbk: ?JSCallback) !void {
        const alloc = self.alloc;
        if (comptime CANCEL_SUPPORTED == false) {
            try self.cancelled.put(alloc, id, {});
            if (js_cbk) |cbk| {
                cbk.call(null) catch {
                    self.cbk_error = true;
                };
            }
            return;
        }
        const comp_cancel: *IO.Completion = @ptrFromInt(id);

        const completion = try alloc.create(Completion);
        errdefer alloc.destroy(completion);
        completion.* = undefined;

        const ctx = self.alloc.create(ContextCancel) catch unreachable;
        ctx.* = ContextCancel{
            .loop = self,
            .js_cbk = js_cbk,
            .js_ctx_id = self.js_ctx_id,
        };

        self.addEvent(.js);
        self.io.cancel_one(*ContextCancel, ctx, cancelCallback, completion, comp_cancel);
    }

    // Reset all existing JS callbacks.
    // The existing events will happen and their memory will be cleanup but the
    // corresponding callbacks will not be called.
    pub fn resetJS(self: *Self) void {
        self.js_ctx_id += 1;
        self.cancelled.clearRetainingCapacity();
    }

    // Reset all existing Zig callbacks.
    // The existing events will happen and their memory will be cleanup but the
    // corresponding callbacks will not be called.
    pub fn resetZig(self: *Self) void {
        self.zig_ctx_id += 1;
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
                defer callback.loop.event_callback_pool.destroy(callback);
                callback.loop.removeEvent(.js);
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onConnect;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.addEvent(.js);
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
                defer callback.loop.event_callback_pool.destroy(callback);
                callback.loop.removeEvent(.js);
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onSend;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.addEvent(.js);
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
                defer callback.loop.event_callback_pool.destroy(callback);
                callback.loop.removeEvent(.js);
                cbk(@alignCast(@ptrCast(callback.ctx)), completion_, res);
            }
        }.onRecv;

        const callback = try self.event_callback_pool.create();
        errdefer self.event_callback_pool.destroy(callback);
        callback.* = .{ .loop = self, .ctx = ctx };

        self.addEvent(.js);
        self.io.recv(*EventCallbackContext, callback, onRecv, completion, socket, buf);
    }

    // Zig timeout

    const ContextZigTimeout = struct {
        loop: *Self,
        zig_ctx_id: u32,

        context: *anyopaque,
        callback: *const fn (
            context: ?*anyopaque,
        ) void,
    };

    fn zigTimeoutCallback(
        ctx: *ContextZigTimeout,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        const loop = ctx.loop;
        defer {
            loop.removeEvent(.zig);
            loop.alloc.destroy(ctx);
            loop.alloc.destroy(completion);
        }

        // If the loop's context id has changed, don't call the js callback
        // function. The callback's memory has already be cleaned and the
        // events nb reset.
        if (ctx.zig_ctx_id != loop.zig_ctx_id) return;

        result catch |err| {
            switch (err) {
                error.Canceled => {},
                else => log.err("zig timeout callback: {any}", .{err}),
            }
            return;
        };

        // callback
        ctx.callback(ctx.context);
    }

    // zigTimeout performs a timeout but the callback is a zig function.
    pub fn zigTimeout(
        self: *Self,
        nanoseconds: u63,
        comptime Context: type,
        context: Context,
        comptime callback: fn (context: Context) void,
    ) void {
        const completion = self.alloc.create(IO.Completion) catch unreachable;
        completion.* = undefined;
        const ctxtimeout = self.alloc.create(ContextZigTimeout) catch unreachable;
        ctxtimeout.* = ContextZigTimeout{
            .loop = self,
            .zig_ctx_id = self.zig_ctx_id,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque) void {
                    callback(@ptrCast(@alignCast(ctx)));
                }
            }.wrapper,
        };

        self.addEvent(.zig);
        self.io.timeout(*ContextZigTimeout, ctxtimeout, zigTimeoutCallback, completion, nanoseconds);
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
