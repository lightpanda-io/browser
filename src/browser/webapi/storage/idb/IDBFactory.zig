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

const js = @import("../../../js/js.zig");

const Key = @import("Key.zig");
const Engine = @import("Engine.zig");
const IDBRequest = @import("IDBRequest.zig");
const IDBDatabase = @import("IDBDatabase.zig");
const IDBTransaction = @import("IDBTransaction.zig");

const log = lp.log;
const Execution = js.Execution;

const IDBFactory = @This();

_pad: bool = false,

pub fn open(_: *IDBFactory, name: []const u8, version: ?u64, exec: *Execution) !*IDBRequest {
    if (exec.origin() == null) {
        // unavailable for opaque origins, e.g. about:blank
        return error.SecurityError;
    }

    // A supplied version must be >= 1; open(name, 0) is a TypeError per spec.
    if (version) |v| {
        if (v == 0) return error.TypeError;
    }

    const request = try IDBRequest.init(exec);

    const ctx = try exec._factory.create(OpenContext{
        .request = request,
        .name = try exec.dupeString(name),
        .version = version,
        .exec = exec,
        ._gate_waiter = .{ .ctx = exec.js, .wake = OpenContext.wakeUp, .cancel = OpenContext.cancelParked },
    });

    try exec.js.scheduler.add(ctx, OpenContext.run, 0, .{
        .name = "IDBFactory.open",
        .finalizer = OpenContext.cancelled,
    });
    return request;
}

const OpenContext = struct {
    request: *IDBRequest,
    name: []const u8,
    version: ?u64,
    exec: *Execution,
    // Our node in the engine's connection gate wait-list. See Engine.acquireGate.
    _gate_waiter: Engine.GateWaiter,
    // Whether a scheduler task currently points at us; its finalizer owns our
    // destruction then. When parked on the gate instead, cancelParked owns it.
    _scheduled: bool = true,

    fn cancelled(ctx: *anyopaque) void {
        // What if we're gated? Well, A scheduled task is only canceled on
        // teardown, which would have already called Engine.detach(js_ctx).
        const self: *OpenContext = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    // Engine.detach cancel: our context is going away while we sit on the
    // gate. When parked there's no scheduler task, so we own our destruction;
    // in the wake->run window the task finalizer does.
    fn cancelParked(waiter: *Engine.GateWaiter) void {
        const self: *OpenContext = @fieldParentPtr("_gate_waiter", waiter);
        if (!self._scheduled) {
            self.exec._factory.destroy(self);
        }
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *OpenContext = @ptrCast(@alignCast(ctx));
        self._scheduled = false;

        const engine = self.resolveEngine() catch |err| {
            self.exec._factory.destroy(self);
            self.request.setError(err);
            self.request.deliver(self.exec) catch {};
            return null;
        };

        // An open that upgrades runs a versionchange transaction on the shared
        // connection, so it must serialize with other transactions/opens. Park
        // on the gate if it's held; wakeUp re-runs us when it's handed over.
        if (!engine.acquireGate(&self._gate_waiter)) {
            return null; // parked; not destroyed
        }
        defer self.exec._factory.destroy(self);
        defer _ = engine.releaseGate(&self._gate_waiter);

        self.runOpen(engine) catch |err| {
            log.warn(.storage, "idb open", .{ .err = err, .name = self.name });
            self.request.setError(err);
            self.request.deliver(self.exec) catch {};
        };
        return null;
    }

    // Scheduler wake-up: the connection gate was handed to us, so re-run.
    fn wakeUp(waiter: *Engine.GateWaiter) void {
        const self: *OpenContext = @fieldParentPtr("_gate_waiter", waiter);
        self.exec.js.scheduler.add(self, run, 0, .{
            .name = "IDBFactory.open",
            .finalizer = cancelled,
        }) catch |err| {
            // We were handed the gate; if we can't reschedule, hand it off so the
            // waiters behind us aren't stranded.
            log.warn(.storage, "idb resume open", .{ .err = err });
            if (self.resolveEngine()) |engine| _ = engine.releaseGate(&self._gate_waiter) else |_| {}
            self.exec._factory.destroy(self);
        };
        self._scheduled = true;
    }

    fn resolveEngine(self: *OpenContext) !*Engine {
        // origin being null was already guarded against, so this should be
        // unreachable, but this is safer.
        const origin = self.exec.origin() orelse return error.SecurityError;
        return self.exec.session.idb.engineForOrigin(origin);
    }

    fn runOpen(self: *OpenContext, engine: *Engine) !void {
        const exec = self.exec;
        const existing = try engine.databaseVersion(self.name);

        // No explicit version means "open at the current version" (or 1 for a
        // brand-new database).
        const requested: i64 = if (self.version) |v| @intCast(v) else existing orelse 1;

        if (existing) |current| {
            if (requested < current) {
                self.request.setError(error.VersionError);
                self.request.deliver(exec) catch {};
                return;
            }

            if (requested == current) {
                const database_id = (try engine.databaseId(self.name)).?;
                const db = try IDBDatabase.init(exec, engine, database_id, self.name, current);
                self.request.setDatabaseResult(db);
                return self.request.fireSuccess(exec);
            }
        }

        // New database or an upgrade to a higher version. Run a versionchange
        // transaction so user JS can evolve the schema during `upgradeneeded`;
        // it's exposed as `request.transaction` and committed here once the
        // handler returns.
        try engine.begin();

        var closed = false;
        errdefer if (closed == false) {
            engine.rollback();
        };

        const database_id = try engine.upsertDatabase(self.name, requested);
        const db = try IDBDatabase.init(exec, engine, database_id, self.name, requested);
        self.request.setDatabaseResult(db);

        const txn = try IDBTransaction.initVersionChange(db, exec);
        txn.acquireRef();
        defer txn.releaseRef(exec.page);

        self.request._txn = .{ .borrowed = txn };
        // The request is page-scoped and must never outlive this pointer; the
        // success/abort paths below null it before delivering, this covers the
        // error paths.
        defer self.request._txn = .none;

        {
            db._txn = txn;
            defer db._txn = null;
            const old_version: u64 = @intCast(existing orelse 0);
            try self.request.fireUpgradeNeeded(exec, old_version, @intCast(requested));
        }

        if (txn.aborted()) {
            // updateneeded handler called abort() (what a jerk!) — abort() already
            // rolled back.
            closed = true;
            self.request._txn = .none;
            self.request.setError(error.AbortError);
            return self.request.deliver(exec);
        }

        txn.settle(exec);
        closed = true;
        self.request._txn = .none;
        return self.request.fireSuccess(exec);
    }
};

pub fn deleteDatabase(_: *IDBFactory, name: []const u8, exec: *Execution) !*IDBRequest {
    if (exec.origin() == null) {
        // unavailable for opaque origins, e.g. about:blank
        return error.SecurityError;
    }

    const request = try IDBRequest.init(exec);

    const ctx = try exec._factory.create(DeleteContext{
        .request = request,
        .name = try exec.dupeString(name),
        .exec = exec,
        ._gate_waiter = .{ .ctx = exec.js, .wake = DeleteContext.wakeUp, .cancel = DeleteContext.cancelParked },
    });

    try exec.js.scheduler.add(ctx, DeleteContext.run, 0, .{
        .name = "IDBFactory.deleteDatabase",
        .finalizer = DeleteContext.cancelled,
    });
    return request;
}

const DeleteContext = struct {
    request: *IDBRequest,
    name: []const u8,
    exec: *Execution,
    _gate_waiter: Engine.GateWaiter,
    // See OpenContext._scheduled.
    _scheduled: bool = true,

    fn cancelled(ctx: *anyopaque) void {
        // What if we're gated? Well, A scheduled task is only canceled on
        // teardown, which would have already called Engine.detach(js_ctx).
        const self: *DeleteContext = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    // See OpenContext.cancelParked.
    fn cancelParked(waiter: *Engine.GateWaiter) void {
        const self: *DeleteContext = @fieldParentPtr("_gate_waiter", waiter);
        if (!self._scheduled) {
            self.exec._factory.destroy(self);
        }
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeleteContext = @ptrCast(@alignCast(ctx));
        self._scheduled = false;

        const engine = self.resolveEngine() catch |err| {
            self.exec._factory.destroy(self);
            self.request.setError(err);
            self.request.deliver(self.exec) catch {};
            return null;
        };

        if (!engine.acquireGate(&self._gate_waiter)) {
            return null; // parked; not destroyed
        }
        defer self.exec._factory.destroy(self);
        defer _ = engine.releaseGate(&self._gate_waiter);

        self.runDelete(engine) catch |err| {
            log.warn(.storage, "idb deleteDatabase", .{ .err = err, .name = self.name });
            self.request.setError(err);
            self.request.deliver(self.exec) catch {};
        };
        return null;
    }

    // Scheduler wake-up: the connection gate was handed to us, so re-run.
    fn wakeUp(waiter: *Engine.GateWaiter) void {
        const self: *DeleteContext = @fieldParentPtr("_gate_waiter", waiter);
        self.exec.js.scheduler.add(self, run, 0, .{
            .name = "IDBFactory.deleteDatabase",
            .finalizer = cancelled,
        }) catch |err| {
            // We were handed the gate; if we can't reschedule, hand it off so the
            // waiters behind us aren't stranded.
            log.warn(.storage, "idb resume delete", .{ .err = err });
            if (self.resolveEngine()) |engine| _ = engine.releaseGate(&self._gate_waiter) else |_| {}
            self.exec._factory.destroy(self);
        };
        self._scheduled = true;
    }

    fn resolveEngine(self: *DeleteContext) !*Engine {
        const origin = self.exec.origin() orelse return error.SecurityError;
        return self.exec.session.idb.engineForOrigin(origin);
    }

    fn runDelete(self: *DeleteContext, engine: *Engine) !void {
        try engine.deleteDatabase(self.name);
        return self.request.fireSuccess(self.exec);
    }
};

pub fn cmp(_: *IDBFactory, first: js.Value, second: js.Value, exec: *Execution) !i32 {
    const a = try Key.encodeValue(exec.call_arena, first);
    const b = try Key.encodeValue(exec.call_arena, second);
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBFactory);

    pub const Meta = struct {
        pub const name = "IDBFactory";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const open = bridge.function(IDBFactory.open, .{});
    pub const deleteDatabase = bridge.function(IDBFactory.deleteDatabase, .{});
    pub const cmp = bridge.function(IDBFactory.cmp, .{});
};
