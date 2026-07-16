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

const idb = @import("idb.zig");
const Key = @import("Key.zig");
const Engine = @import("Engine.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");
const DOMStringList = @import("../../collections.zig").DOMStringList;

const FunctionSetter = idb.FunctionSetter;

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const IDBDatabase = @This();

_proto: *EventTarget,
_exec: *Execution,
_engine: *Engine,
_database_id: i64,
_name: []const u8,
_version: i64,
_txn: ?*IDBTransaction = null, // only set during upgradeneeded
_on_error: ?js.Function.Global = null,

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
    keyPath: ?Key.KeyPath = null,
    autoIncrement: bool = false,
};

// Only callable while the upgrade transaction is live and active, hence the checks
pub fn createObjectStore(
    self: *IDBDatabase,
    name: []const u8,
    options: ?CreateObjectStoreOptions,
) !*IDBObjectStore {
    const txn = self._txn orelse return error.InvalidStateError;
    if (txn._settled) {
        return error.InvalidStateError;
    }
    try txn.assertActive();

    const opts = options orelse CreateObjectStoreOptions{};

    // Validate + copy the key path onto the transaction arena so it outlives the
    // call. autoIncrement is incompatible with an empty or compound key path.
    const key_path: ?Key.KeyPath = if (opts.keyPath) |kp| blk: {
        if (Key.isValidKeyPathSpec(kp) == false) {
            return error.SyntaxError;
        }
        if (opts.autoIncrement and keyPathBlocksAutoIncrement(kp)) {
            return error.InvalidAccessError;
        }
        break :blk try Key.dupeKeyPath(txn._arena, kp);
    } else null;

    const store_id = self._engine.createObjectStore(
        txn._arena,
        self._database_id,
        name,
        key_path,
        opts.autoIncrement,
    ) catch |err| switch (err) {
        error.Constraint => return error.ConstraintError,
        else => return err,
    };

    const owned_name = try txn.dupe(name);
    const store = try IDBObjectStore.init(txn, store_id, owned_name, key_path, opts.autoIncrement);
    store._created = true;
    try txn.cacheStore(store);
    return store;
}

// autoIncrement requires an out-of-line or single-property in-line key; an empty
// or compound key path can't carry a generated key.
fn keyPathBlocksAutoIncrement(kp: Key.KeyPath) bool {
    return switch (kp) {
        .string => |s| s.len == 0,
        .list => true,
    };
}

// Only callable while the upgrade transaction is live and active, hence the checks
pub fn deleteObjectStore(self: *IDBDatabase, name: []const u8, _: *Execution) !void {
    const txn = self._txn orelse return error.InvalidStateError;
    if (txn._settled) {
        return error.InvalidStateError;
    }
    try txn.assertActive();
    try self._engine.deleteObjectStore(self._database_id, name);
    txn.uncacheStore(name);
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
    const opts = options orelse TransactionOptions{};
    const txn = try IDBTransaction.init(self, switch (mode orelse .readonly) {
        .readonly => .readonly,
        .readwrite => .readwrite,
    }, opts.durability, exec);
    txn._scope = try normalizeStoreNames(txn._arena, store_names);
    return txn;
}

// The transaction's scope: the requested store names, sorted with duplicates
// removed (per the IndexedDB spec's "transaction scope" steps).
fn normalizeStoreNames(arena: Allocator, store_names: StoreNames) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    switch (store_names) {
        .name => |name| try list.append(arena, try arena.dupe(u8, name)),
        .names => |names| {
            try list.ensureUnusedCapacity(arena, names.len);
            for (names) |name| {
                list.appendAssumeCapacity(try arena.dupe(u8, name));
            }
        },
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Drop duplicates now that equal names are adjacent. The first name always
    // survives, so only the rest need comparing.
    if (list.items.len <= 1) {
        return list.items;
    }

    var write: usize = 1;
    for (list.items[1..]) |name| {
        if (!std.mem.eql(u8, name, list.items[write - 1])) {
            list.items[write] = name;
            write += 1;
        }
    }
    return list.items[0..write];
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

pub fn getObjectStoreNames(self: *IDBDatabase, exec: *Execution) !*DOMStringList {
    const arena = try exec.getArena(.small, "IDB.getObjectStoreNames");
    errdefer exec.releaseArena(arena);

    const names = try self._engine.objectStoreNames(arena, self._database_id);
    const list = try arena.create(DOMStringList);
    list.* = .{ ._items = names, ._arena = arena };
    return list;
}

pub fn getOnError(self: *const IDBDatabase) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *IDBDatabase, setter: ?FunctionSetter) void {
    self._on_error = if (setter) |s| switch (s) {
        .func => |f| f,
        .anything => null,
    } else null;
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
    pub const objectStoreNames = bridge.accessor(IDBDatabase.getObjectStoreNames, null, .{});
    pub const createObjectStore = bridge.function(IDBDatabase.createObjectStore, .{});
    pub const deleteObjectStore = bridge.function(IDBDatabase.deleteObjectStore, .{});
    pub const transaction = bridge.function(IDBDatabase.transaction, .{});
    pub const close = bridge.function(IDBDatabase.close, .{});
    pub const onerror = bridge.accessor(IDBDatabase.getOnError, IDBDatabase.setOnError, .{});
};
