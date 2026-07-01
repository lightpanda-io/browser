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

    fn cancelled(ctx: *anyopaque) void {
        const self: *OpenContext = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *OpenContext = @ptrCast(@alignCast(ctx));
        defer self.exec._factory.destroy(self);

        self.runOpen() catch |err| {
            log.warn(.storage, "idb open", .{ .err = err, .name = self.name });
            self.request.setError(err);
            self.request.deliver(self.exec) catch {};
        };
        return null;
    }

    fn runOpen(self: *OpenContext) !void {
        const exec = self.exec;

        // origin being null was already guarded against, so this should be
        // unreachable, but this is safer.
        const origin = exec.origin() orelse return error.SecurityError;

        const engine = try exec.session.idb.engineForOrigin(origin);
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

        const txn = try IDBTransaction.initVersionChange(exec, db);
        self.request._txn = txn;

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
            self.request._txn = null;
            self.request.setError(error.AbortError);
            return self.request.deliver(exec);
        }

        txn.settle(exec);
        closed = true;
        self.request._txn = null;
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

    fn cancelled(ctx: *anyopaque) void {
        const self: *DeleteContext = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeleteContext = @ptrCast(@alignCast(ctx));
        defer self.exec._factory.destroy(self);

        self.runDelete() catch |err| {
            log.warn(.storage, "idb deleteDatabase", .{ .err = err, .name = self.name });
            self.request.setError(err);
            self.request.deliver(self.exec) catch {};
        };
        return null;
    }

    fn runDelete(self: *DeleteContext) !void {
        const exec = self.exec;
        const origin = exec.origin() orelse return error.SecurityError;
        const engine = try exec.session.idb.engineForOrigin(origin);
        try engine.deleteDatabase(self.name);
        return self.request.fireSuccess(exec);
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
