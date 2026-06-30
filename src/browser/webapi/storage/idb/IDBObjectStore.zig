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

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");

const Key = @import("Key.zig");
const Engine = @import("Engine.zig");
const IDBCursor = @import("IDBCursor.zig");
const IDBRequest = @import("IDBRequest.zig");
const IDBKeyRange = @import("IDBKeyRange.zig");
const IDBTransaction = @import("IDBTransaction.zig");

const log = lp.log;
const Execution = js.Execution;

const IDBObjectStore = @This();

_engine: *Engine,
_store_id: i64,
_name: []const u8,
_key_path: ?[]const u8,
_auto_increment: bool,
// only null during an upgradeneeded
_txn: ?*IDBTransaction,

pub fn init(
    engine: *Engine,
    txn: ?*IDBTransaction,
    store_id: i64,
    name: []const u8,
    key_path: ?[]const u8,
    auto_increment: bool,
    exec: *Execution,
) !*IDBObjectStore {
    return exec._factory.create(IDBObjectStore{
        ._engine = engine,
        ._txn = txn,
        ._store_id = store_id,
        ._name = name,
        ._key_path = key_path,
        ._auto_increment = auto_increment,
    });
}

pub fn add(self: *IDBObjectStore, value: js.Value, key: ?js.Value, exec: *Execution) !*IDBRequest {
    return self.write(value, key, .add, exec);
}

pub fn put(self: *IDBObjectStore, value: js.Value, key: ?js.Value, exec: *Execution) !*IDBRequest {
    return self.write(value, key, .put, exec);
}

pub fn get(self: *IDBObjectStore, query: js.Value, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    // Both the encoded key and the fetched bytes are consumed within this call
    // (the bytes are deserialized below), so the per-call scratch arena suffices.
    const arena = exec.call_arena;
    const bounds = try IDBKeyRange.resolveQuery(arena, query, exec);
    const request = try txn.newRequest();

    const bytes = self._engine.getRange(arena, self._store_id, bounds) catch |err| {
        log.warn(.storage, "idb get", .{ .err = err });
        request.setError(err);
        return request;
    };

    const b = bytes orelse return request;

    const value = try js.Value.deserialize(exec.js.local.?, b);
    try request.setValue(value);
    return request;
}

pub fn delete(self: *IDBObjectStore, query: js.Value, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.ensureBegun();

    const bounds = try IDBKeyRange.resolveQuery(exec.call_arena, query, exec);
    const request = try txn.newRequest();

    self._engine.deleteRange(self._store_id, bounds) catch |err| {
        log.warn(.storage, "idb delete", .{ .err = err });
        request.setError(err);
    };
    return request;
}

pub fn clear(self: *IDBObjectStore, _: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.ensureBegun();

    const request = try txn.newRequest();
    self._engine.clear(self._store_id) catch |err| {
        log.warn(.storage, "idb clear", .{ .err = err });
        request.setError(err);
    };
    return request;
}

pub fn count(self: *IDBObjectStore, query: ?js.Value, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    const bounds = try IDBKeyRange.resolveQuery(exec.call_arena, query, exec);
    const request = try txn.newRequest();
    const n = self._engine.countRange(self._store_id, bounds) catch |err| {
        log.warn(.storage, "idb count", .{ .err = err });
        request.setError(err);
        return request;
    };
    try request.setValue(try exec.js.local.?.zigValueToJs(n, .{}));
    return request;
}

pub fn getAll(self: *IDBObjectStore, query: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    const local = exec.js.local.?;
    const arena = exec.call_arena;
    const bounds = try IDBKeyRange.resolveQuery(arena, query, exec);
    const request = try txn.newRequest();

    const values = self._engine.getAllRange(arena, self._store_id, bounds, .value, count_) catch |err| {
        log.warn(.storage, "idb getAll", .{ .err = err });
        request.setError(err);
        return request;
    };

    const arr = local.newArray(@intCast(values.len));
    for (values, 0..) |bytes, i| {
        const value = try js.Value.deserialize(local, bytes);
        _ = try arr.set(@intCast(i), value, .{});
    }
    try request.setValue(arr.toValue());
    return request;
}

pub fn getKey(self: *IDBObjectStore, query: js.Value, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    const arena = exec.call_arena;
    const bounds = try IDBKeyRange.resolveQuery(arena, query, exec);
    const request = try txn.newRequest();

    const found = self._engine.getKeyRange(arena, self._store_id, bounds) catch |err| {
        log.warn(.storage, "idb getKey", .{ .err = err });
        request.setError(err);
        return request;
    };

    const bytes = found orelse return request; // no record -> undefined
    try request.setValue(try Key.decodeToJs(arena, exec.js.local.?, bytes));
    return request;
}

pub fn getAllKeys(self: *IDBObjectStore, query: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    const arena = exec.call_arena;
    const bounds = try IDBKeyRange.resolveQuery(arena, query, exec);
    const request = try txn.newRequest();

    const keys = self._engine.getAllRange(arena, self._store_id, bounds, .key, count_) catch |err| {
        log.warn(.storage, "idb getAllKeys", .{ .err = err });
        request.setError(err);
        return request;
    };

    const local = exec.js.local.?;
    const arr = local.newArray(@intCast(keys.len));
    for (keys, 0..) |bytes, i| {
        _ = try arr.set(@intCast(i), try Key.decodeToJs(arena, local, bytes), .{});
    }
    try request.setValue(arr.toValue());
    return request;
}

pub fn openCursor(self: *IDBObjectStore, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    const bounds = try IDBKeyRange.resolveQuery(exec.arena, query, exec);
    return IDBCursor.open(self, bounds, direction orelse .next, false, exec);
}

pub fn openKeyCursor(self: *IDBObjectStore, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    const bounds = try IDBKeyRange.resolveQuery(exec.arena, query, exec);
    return IDBCursor.open(self, bounds, direction orelse .next, true, exec);
}

pub fn getName(self: *const IDBObjectStore) []const u8 {
    return self._name;
}

pub fn getKeyPath(self: *const IDBObjectStore) ?[]const u8 {
    return self._key_path;
}

pub fn getAutoIncrement(self: *const IDBObjectStore) bool {
    return self._auto_increment;
}

pub fn getTransaction(self: *IDBObjectStore) ?*IDBTransaction {
    return self._txn;
}

const WriteKind = enum { add, put };

fn write(self: *IDBObjectStore, value: js.Value, key_arg: ?js.Value, kind: WriteKind, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.ensureBegun();

    const local = exec.js.local.?;

    var generated = false;
    const key_value: js.Value = blk: {
        if (self._key_path) |kp| {
            if (key_arg != null) {
                // can't have an explicit key if we're configured for in-line keys
                return error.DataError;
            }

            if (Key.evaluatePath(value, kp)) |extracted| {
                break :blk extracted;
            }

            // The keypath wasn't in the value...
            if (self._auto_increment == false) {
                // and auto-increment is disabled, no key, error.
                return error.DataError;
            }

            if (Key.canInjectKey(value, kp) == false) {
                return error.DataError;
            }

            generated = true;
            const n = try self._engine.nextGeneratedKey(self._store_id);
            const k = try local.newNumber(@floatFromInt(n));
            try Key.injectKey(local, value, kp, k);
            break :blk k;
        }

        // Out-of-line keys.
        if (key_arg) |k| {
            break :blk k;
        }

        if (self._auto_increment == false) {
            return error.DataError;
        }

        generated = true;
        const n = try self._engine.nextGeneratedKey(self._store_id);
        break :blk try local.newNumber(@floatFromInt(n));
    };

    const encoded = try Key.encodeValue(exec.call_arena, key_value);

    if (self._auto_increment and !generated and key_value.isNumber()) {
        // auto-increment is enabled, but this was NOT a generated key, so we
        // need to bump the generator so that future generated keys don't collide
        try self._engine.maybeBumpGenerator(self._store_id, try key_value.toF64());
    }

    const serialized = try value.serialize();
    defer serialized.deinit();

    const request = try txn.newRequest();

    const result = switch (kind) {
        .add => self._engine.add(self._store_id, encoded, serialized.bytes()),
        .put => self._engine.put(self._store_id, encoded, serialized.bytes()),
    };
    result catch |err| {
        log.warn(.storage, "idb write", .{ .err = err, .kind = kind });
        request.setError(err);
        return request;
    };

    try request.setValue(key_value);
    return request;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBObjectStore);

    pub const Meta = struct {
        pub const name = "IDBObjectStore";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(IDBObjectStore.getName, null, .{});
    pub const keyPath = bridge.accessor(IDBObjectStore.getKeyPath, null, .{});
    pub const autoIncrement = bridge.accessor(IDBObjectStore.getAutoIncrement, null, .{});
    pub const transaction = bridge.accessor(IDBObjectStore.getTransaction, null, .{ .null_as_undefined = true });
    pub const add = bridge.function(IDBObjectStore.add, .{ });
    pub const put = bridge.function(IDBObjectStore.put, .{ });
    pub const get = bridge.function(IDBObjectStore.get, .{ });
    pub const getKey = bridge.function(IDBObjectStore.getKey, .{ });
    pub const delete = bridge.function(IDBObjectStore.delete, .{ });
    pub const clear = bridge.function(IDBObjectStore.clear, .{ });
    pub const count = bridge.function(IDBObjectStore.count, .{ });
    pub const getAll = bridge.function(IDBObjectStore.getAll, .{ });
    pub const getAllKeys = bridge.function(IDBObjectStore.getAllKeys, .{ });
    pub const openCursor = bridge.function(IDBObjectStore.openCursor, .{ });
    pub const openKeyCursor = bridge.function(IDBObjectStore.openKeyCursor, .{ });
};
