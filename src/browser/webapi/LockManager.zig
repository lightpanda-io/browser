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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = @import("../js/Execution.zig");
const AbortSignal = @import("AbortSignal.zig");

const Lock = @import("Lock.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/LockManager
// https://w3c.github.io/web-locks/#api-lock-manager
const LockManager = @This();

_locks: std.ArrayList(*LockRequest) = .empty,

pub const Options = struct {
    ifAvailable: bool = false,
    mode: Lock.LockMode = .exclusive,
    signal: ?*AbortSignal = null,
    steal: bool = false,
};

const LockState = enum { pending, held };

// A pending or in-flight lock request
const LockRequest = struct {
    manager: *LockManager,
    name: lp.String,
    options: Options,
    state: LockState,
    cb: js.Function.Global,
    resolver: js.PromiseResolver.Global,
    exec: *Execution,
    client_id: []const u8,

    granted: bool,
    finished: bool = false,

    fn deinit(self: *LockRequest) void {
        self.cb.release();
        self.resolver.release();
    }

    fn finish(self: *LockRequest) void {
        if (self.finished) return;
        self.finished = true;

        if (self.granted) {
            self.manager.releaseLock(self);
        } else {
            self.deinit();
        }
    }

    fn onFulfilled(self: *LockRequest, value: ?js.Value) void {
        if (self.finished) return;

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const resolver = self.resolver.local(&ls.local);
        resolver.resolve("Lock callback result", value.?);
        self.finish();
    }

    fn onRejected(self: *LockRequest, value: ?js.Value) void {
        if (self.finished) return;

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const resolver = self.resolver.local(&ls.local);
        resolver.reject("Lock callback result", value.?);
        self.finish();
    }

    fn fireCallbackWith(self: *LockRequest, lock: ?Lock) void {
        if (self.finished) return;
        self.granted = lock != null;

        const exec = self.exec;

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        const local = &ls.local;
        const resolver = self.resolver.local(local);

        if (self.granted) {
            if (self.options.signal) |signal| {
                if (signal._aborted) {
                    resolver.reject("LockManager.signal.aborted", signal._reason);
                    self.finish();
                    return;
                }
            }
        }

        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        const callback_fn: js.Function = ls.toLocal(self.cb);

        const result = callback_fn.callRethrow(js.Value, .{lock}) catch |err| {
            if (err == error.ExecutionTerminated) {
                self.finish();
                return;
            }
            if (try_catch.exceptionValue()) |exception| {
                resolver.reject("Lock callback", exception);
            } else {
                resolver.rejectError("Lock callback", .{ .generic_error = @errorName(err) });
            }
            self.finish();
            return;
        };

        if (result.isPromise() == false) {
            resolver.resolve("Lock callback result", result);
            self.finish();
            return;
        }

        const on_fulfilled = local.newCallback(LockRequest.onFulfilled, self);
        const on_rejected = local.newCallback(LockRequest.onRejected, self);
        _ = result.toPromise().thenAndCatch(on_fulfilled, on_rejected) catch {
            self.finish();
        };
    }

    fn fireCallback(self: *LockRequest) void {
        self.fireCallbackWith(Lock{
            ._mode = self.options.mode,
            ._name = self.name,
        });
    }

    fn scheduleFireCallback(self: *LockRequest) void {
        self.exec.js.scheduler.add(self, runFireCallback, 0, .{
            .name = "weblocks.fireCallback",
            .finalizer = cancelled,
        }) catch self.fireCallback();
    }

    fn runFireCallback(ctx: *anyopaque) anyerror!?u32 {
        const self: *LockRequest = @ptrCast(@alignCast(ctx));
        self.fireCallback();
        return null;
    }

    fn scheduleFireCallbackWithNull(self: *LockRequest) void {
        self.exec.js.scheduler.add(self, runFireCallbackWithNull, 0, .{
            .name = "weblocks.fireCallbackWithNull",
            .finalizer = cancelled,
        }) catch self.fireCallbackWith(null);
    }

    fn runFireCallbackWithNull(ctx: *anyopaque) anyerror!?u32 {
        const self: *LockRequest = @ptrCast(@alignCast(ctx));
        self.fireCallbackWith(null);
        return null;
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *LockRequest = @ptrCast(@alignCast(ctx));
        if (self.finished) return;
        self.finished = true;
        self.deinit();
    }
};

fn heldConflicts(self: *const LockManager, name: lp.String, mode: Lock.LockMode) bool {
    for (self._locks.items) |li| {
        if (li.state == .held and li.name.eql(name)) switch (mode) {
            .exclusive => return true,
            .shared => if (li.options.mode == .exclusive) {
                return true;
            },
        };
    }

    return false;
}

fn mustQueue(self: *const LockManager, name: lp.String, mode: Lock.LockMode) bool {
    if (self.heldConflicts(name, mode)) {
        return true;
    }

    // If any are pending with the same name, we must queue behind them.
    for (self._locks.items) |lr| {
        if (lr.state == .pending and lr.name.eql(name)) {
            return true;
        }
    }

    return false;
}

const CallbackOrOptions = union(enum) {
    callback: js.Function,
    options: Options,
};

// https://w3c.github.io/web-locks/#dom-lockmanager-request
pub fn request(
    self: *LockManager,
    name: []const u8,
    arg2: CallbackOrOptions,
    cb3: ?js.Function,
    exec: *Execution,
) !js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();
    const promise = resolver.promise();

    const options, const cb = switch (arg2) {
        .callback => |c| .{ Options{}, c },
        .options => |o| blk: {
            const c = cb3 orelse {
                resolver.rejectError(
                    "LockManager.request",
                    .{ .type_error = "callback must be a function" },
                );
                return promise;
            };

            break :blk .{ o, c };
        },
    };

    if ((name.len > 0 and name[0] == '-') or
        (options.steal and options.ifAvailable) or
        (options.steal and options.mode != .exclusive) or
        (options.signal != null and (options.steal or options.ifAvailable)))
    {
        resolver.rejectError(
            "LockManager.request",
            .{ .dom_exception = .{ .err = error.NotSupported } },
        );
        return promise;
    }

    if (options.signal) |signal| {
        if (signal._aborted) {
            resolver.reject("LockManager.signal.aborted", signal._reason);
            return promise;
        }
    }

    const owned_name = try lp.String.init(exec.arena, name, .{});

    const lock_request = try exec.arena.create(LockRequest);
    lock_request.* = .{
        .manager = self,
        .name = owned_name,
        .options = options,
        .state = .pending,
        .cb = try cb.persist(),
        .resolver = try resolver.persist(),
        .exec = exec,
        .client_id = try std.fmt.allocPrint(exec.arena, "{d}", .{exec.frameId()}),
        .granted = false,
    };

    if (options.steal) {
        // All held locks with this name are released with AbortError.
        var i: usize = 0;
        while (i < self._locks.items.len) {
            const lr = self._locks.items[i];
            if (lr.state == .held and lr.name.eql(owned_name)) {
                _ = self._locks.orderedRemove(i);

                const lock_resolver = lr.resolver.local(lr.exec.js.local.?);
                lock_resolver.rejectError(
                    "steal weblock",
                    .{ .dom_exception = .{ .err = error.AbortError } },
                );

                lr.finished = true;
                lr.deinit();
                continue;
            }
            i += 1;
        }

        lock_request.state = .held;
        try self._locks.append(exec.arena, lock_request);
        lock_request.scheduleFireCallback();
        return promise;
    }

    const must_queue_request = self.mustQueue(owned_name, options.mode);

    // ifAvailable and held means we fire the callback with null.
    if (options.ifAvailable and must_queue_request) {
        lock_request.scheduleFireCallbackWithNull();
        return promise;
    }

    if (must_queue_request) {
        try self._locks.append(exec.arena, lock_request);
        return promise;
    }

    lock_request.state = .held;
    try self._locks.append(exec.arena, lock_request);
    lock_request.scheduleFireCallback();
    return promise;
}

// https://w3c.github.io/web-locks/#dom-lockmanager-query
pub fn query(self: *const LockManager, exec: *Execution) !js.Promise {
    var held: std.ArrayList(LockInfo) = .empty;
    var pending: std.ArrayList(LockInfo) = .empty;
    for (self._locks.items) |lr| {
        const info = LockInfo{
            .name = lr.name,
            .mode = @tagName(lr.options.mode),
            .clientId = lr.client_id,
        };
        switch (lr.state) {
            .held => try held.append(exec.arena, info),
            .pending => try pending.append(exec.arena, info),
        }
    }

    const snapshot = LockManagerSnapshot{
        .held = held.items,
        .pending = pending.items,
    };

    return exec.js.local.?.resolvePromise(snapshot);
}

// https://w3c.github.io/web-locks/#lockinfo
const LockInfo = struct {
    name: lp.String,
    mode: []const u8,
    clientId: []const u8,
};

// https://w3c.github.io/web-locks/#lockmanagersnapshot
const LockManagerSnapshot = struct {
    held: []const LockInfo,
    pending: []const LockInfo,
};

fn releaseLock(self: *LockManager, lock_request: *LockRequest) void {
    // Find and remove us from the list of locks.
    for (self._locks.items, 0..) |lr, i| {
        if (lr == lock_request) {
            _ = self._locks.orderedRemove(i);
            break;
        }
    }
    defer lock_request.deinit();

    var to_grant: std.ArrayList(*LockRequest) = .empty;
    for (self._locks.items) |lr| {
        if (lr.state != .pending or !lr.name.eql(lock_request.name)) continue;
        if (self.heldConflicts(lr.name, lr.options.mode)) break;

        lr.state = .held;
        to_grant.append(lock_request.exec.arena, lr) catch {
            lr.state = .pending;
            break;
        };
    }

    for (to_grant.items) |lr| {
        lr.scheduleFireCallback();
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(LockManager);

    pub const Meta = struct {
        pub const name = "LockManager";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const request = bridge.function(LockManager.request, .{});
    pub const query = bridge.function(LockManager.query, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: LockManager" {
    try testing.htmlRunner("weblocks.html", .{});
}
