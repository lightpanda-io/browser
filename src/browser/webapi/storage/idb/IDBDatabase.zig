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

const EventTarget = @import("../../EventTarget.zig");

const Engine = @import("Engine.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");

const Execution = js.Execution;

const IDBDatabase = @This();

_proto: *EventTarget,
_exec: *Execution,
_engine: *Engine,
_database_id: i64,
_name: []const u8,
_version: i64,
_txn: ?*IDBTransaction = null, // only set during upgradeneeded

pub fn init(exec: *Execution, engine: *Engine, database_id: i64, name: []const u8, version: i64) !*IDBDatabase {
    return exec._factory.eventTarget(IDBDatabase{
        ._proto = undefined,
        ._exec = exec,
        ._engine = engine,
        ._database_id = database_id,
        ._name = name,
        ._version = version,
    });
}

pub fn asEventTarget(self: *IDBDatabase) *EventTarget {
    return self._proto;
}

const CreateObjectStoreOptions = struct {
    keyPath: ?[]const u8 = null,
    autoIncrement: bool = false,
};

// Only callable during upgradeneeded, hence the _txn check
pub fn createObjectStore(
    self: *IDBDatabase,
    name: []const u8,
    options: ?CreateObjectStoreOptions,
    exec: *Execution,
) !*IDBObjectStore {
    const txn = self._txn orelse return error.InvalidStateError;

    const opts = options orelse CreateObjectStoreOptions{};
    const store_id = self._engine.createObjectStore(
        self._database_id,
        name,
        opts.keyPath,
        opts.autoIncrement,
    ) catch |err| switch (err) {
        error.Constraint => return error.ConstraintError,
        else => return err,
    };

    const owned_name = try exec.dupeString(name);
    const key_path = if (opts.keyPath) |kp| try exec.dupeString(kp) else null;
    return IDBObjectStore.init(self._engine, txn, store_id, owned_name, key_path, exec);
}

// Only callable during upgradeneeded, hence the _txn check
pub fn deleteObjectStore(self: *IDBDatabase, name: []const u8, _: *Execution) !void {
    if (self._txn == null) {
        return error.InvalidStateError;
    }
    return self._engine.deleteObjectStore(self._database_id, name);
}

const TransactionMode = enum {
    readonly,
    readwrite,
    pub const js_enum_from_string = true;
};

const StoreNames = union(enum) {
    name: []const u8,
    names: []const []const u8,
};

const TransactionOptions = struct {
    durability: IDBTransaction.Durability = .default,
};

pub fn transaction(
    self: *IDBDatabase,
    store_names: StoreNames,
    mode: ?TransactionMode,
    options: ?TransactionOptions,
    exec: *Execution,
) !*IDBTransaction {
    _ = store_names; // TODO
    const opts = options orelse TransactionOptions{};
    return IDBTransaction.init(exec, self, switch (mode orelse .readonly) {
        .readonly => .readonly,
        .readwrite => .readwrite,
    }, opts.durability);
}

pub fn close(_: *IDBDatabase) void {
    // Connections are pooled on the Manager and shared across handles, so a
    // single handle's close() is a no-op for the bare slice.
}

pub fn getName(self: *const IDBDatabase) []const u8 {
    return self._name;
}

pub fn getVersion(self: *const IDBDatabase) i64 {
    return self._version;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBDatabase);

    pub const Meta = struct {
        pub const name = "IDBDatabase";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(IDBDatabase.getName, null, .{});
    pub const version = bridge.accessor(IDBDatabase.getVersion, null, .{});
    pub const createObjectStore = bridge.function(IDBDatabase.createObjectStore, .{ .dom_exception = true });
    pub const deleteObjectStore = bridge.function(IDBDatabase.deleteObjectStore, .{ .dom_exception = true });
    pub const transaction = bridge.function(IDBDatabase.transaction, .{ .dom_exception = true });
    pub const close = bridge.function(IDBDatabase.close, .{});
};
