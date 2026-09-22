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
_pending_locks: std.ArrayList(*Waiter) = .empty,

pub const LockInfo = struct {
    name: lp.String,
    mode: Lock.LockMode,
};

pub const LockManagerState = struct {
    held: []const LockInfo,
    pending: []const LockInfo,
};

// A pending or in-flight lock request
const Waiter = struct {
    manager: *LockManager,
    name: lp.String,
    cb: js.Function.Global,
    resolver: js.PromiseResolver.Global,
    exec: *Execution,

    fn deinit(self: *Waiter) void {
        self.cb.release();
        self.resolver.release();
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
    cb: js.Function,
    exec: *Execution,
) !js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();
    const promise = resolver.promise();

    if (name.len > 0 and name[0] == '-') {
        resolver.rejectError(
            "LockManager.request",
            .{ .dom_exception = .{ .err = error.NotSupported } },
        );
        return promise;
    }

    const owned_name = try lp.String.init(exec.arena, name, .{});

    const waiter = try exec.arena.create(Waiter);
    waiter.* = .{
        .manager = self,
        .name = owned_name,
        .cb = try cb.persist(),
        .resolver = try resolver.persist(),
        .exec = exec,
    };

    if (self.isHeld(owned_name)) {
        try self._pending_locks.append(exec.arena, waiter);
        return promise;
    }

    try self._held_locks.append(exec.arena, .{ .name = owned_name, .mode = .exclusive });
    grant(waiter);
    return promise;
}

// Invokes a waiter's callback with a Lock, resolves its request() promise
// with (or, if it's a promise/thenable, chases) the callback's return value,
// and releases the lock once that value has settled.
fn grant(waiter: *Waiter) void {
    const exec = waiter.exec;

    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();

    const local = &ls.local;
    const resolver = waiter.resolver.local(local);

    const result = ls.toLocal(waiter.cb).call(js.Value, .{Lock{
        ._mode = .exclusive,
        ._name = waiter.name,
    }}) catch |err| {
        resolver.rejectError("Lock callback", .{ .generic_error = @errorName(err) });
        waiter.manager.releaseLock(waiter);
        return;
    };

    // Resolve with the raw result: V8's own Promise Resolution Procedure
    // chases it if it's a promise/thenable. This is independent of when we
    // release the lock below.
    resolver.resolve("Lock callback result", result);

    if (result.isPromise() == false) {
        waiter.manager.releaseLock(waiter);
        return;
    }

    const settled = local.newCallback(onSettled, waiter);
    _ = result.toPromise().thenAndCatch(settled, settled) catch {
        waiter.manager.releaseLock(waiter);
    };
}

fn onSettled(waiter: *Waiter, _: ?js.Value) void {
    waiter.manager.releaseLock(waiter);
}

// Frees the given waiter's held lock, then grants it to the next queued
// waiter for that name (if any).
fn releaseLock(self: *LockManager, waiter: *Waiter) void {
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
        self._held_locks.append(w.exec.arena, .{ .name = w.name, .mode = .exclusive }) catch |err| {
            var ls: js.Local.Scope = undefined;
            w.exec.js.localScope(&ls);
            defer ls.deinit();
            w.resolver.local(&ls.local).rejectError("Lock grant", .{ .generic_error = @errorName(err) });
            w.deinit();
            return;
        };
        grant(w);
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
