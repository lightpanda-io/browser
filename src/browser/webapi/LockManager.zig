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

const Lock = @import("Lock.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/LockManager
// https://w3c.github.io/web-locks/#api-lock-manager
const LockManager = @This();

_held_locks: std.ArrayList(LockInfo) = .empty,
_pending_locks: std.ArrayList(*LockRequest) = .empty,

pub const LockInfo = struct {
    name: lp.String,
    mode: Lock.LockMode,
};

pub const LockManagerState = struct {
    held: []const LockInfo,
    pending: []const LockInfo,
};

pub const Options = struct {
    ifAvailable: bool = false,
    mode: Lock.LockMode = .exclusive,
};

const CallbackOrOptions = union(enum) {
    callback: js.Function,
    options: Options,
};

// A pending or in-flight lock request
const LockRequest = struct {
    manager: *LockManager,
    name: lp.String,
    options: Options,
    cb: js.Function.Global,
    resolver: js.PromiseResolver.Global,
    exec: *Execution,

    granted: bool,

    fn deinit(self: *LockRequest) void {
        self.cb.release();
        self.resolver.release();
    }

    fn finish(self: *LockRequest) void {
        if (self.granted) {
            self.manager.releaseLock(self);
        } else {
            self.deinit();
        }
    }

    fn onSettled(self: *LockRequest, _: ?js.Value) void {
        self.finish();
    }

    fn grantWith(self: *LockRequest, lock: ?Lock) void {
        self.granted = lock != null;

        const exec = self.exec;

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        const local = &ls.local;
        const resolver = self.resolver.local(local);

        const result = ls.toLocal(self.cb).call(
            js.Value,
            .{lock},
        ) catch |err| {
            resolver.rejectError("Lock callback", .{ .generic_error = @errorName(err) });
            self.finish();
            return;
        };

        resolver.resolve("Lock callback result", result);

        if (result.isPromise() == false) {
            self.finish();
            return;
        }

        const settled = local.newCallback(LockRequest.onSettled, self);
        _ = result.toPromise().thenAndCatch(settled, settled) catch {
            self.finish();
        };
    }

    fn grant(self: *LockRequest) void {
        self.grantWith(Lock{
            ._mode = self.options.mode,
            ._name = self.name,
        });
    }
};

fn isHeld(self: *const LockManager, name: lp.String) bool {
    for (self._held_locks.items) |li| {
        if (li.name.eql(name)) return true;
    }
    return false;
}

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

    if (name.len > 0 and name[0] == '-') {
        resolver.rejectError(
            "LockManager.request",
            .{ .dom_exception = .{ .err = error.NotSupported } },
        );
        return promise;
    }

    const owned_name = try lp.String.init(exec.arena, name, .{});

    const waiter = try exec.arena.create(LockRequest);
    waiter.* = .{
        .manager = self,
        .name = owned_name,
        .options = options,
        .cb = try cb.persist(),
        .resolver = try resolver.persist(),
        .exec = exec,
        .granted = false,
    };

    const held = self.isHeld(owned_name);

    // ifAvailable and held means we fire the callback with null.
    if (options.ifAvailable and held) {
        waiter.grantWith(null);
        return promise;
    }

    if (held) {
        try self._pending_locks.append(exec.arena, waiter);
        return promise;
    }

    try self._held_locks.append(exec.arena, .{
        .name = owned_name,
        .mode = options.mode,
    });
    waiter.grant();
    return promise;
}

// Frees the given waiter's held lock, then grants it to the next queued
// waiter for that name (if any).
fn releaseLock(self: *LockManager, waiter: *LockRequest) void {
    for (self._held_locks.items, 0..) |li, i| {
        if (li.name.eql(waiter.name)) {
            _ = self._held_locks.orderedRemove(i);
            break;
        }
    }
    waiter.deinit();

    for (self._pending_locks.items, 0..) |w, i| {
        if (w.name.eql(waiter.name) == false) continue;
        _ = self._pending_locks.orderedRemove(i);

        self._held_locks.append(w.exec.arena, .{
            .name = w.name,
            .mode = w.options.mode,
        }) catch |err| {
            var ls: js.Local.Scope = undefined;
            w.exec.js.localScope(&ls);
            defer ls.deinit();
            w.resolver.local(&ls.local).rejectError("Lock grant", .{ .generic_error = @errorName(err) });
            w.deinit();
            return;
        };

        w.grant();
        return;
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
};
