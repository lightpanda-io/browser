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
const IDBIndex = @import("IDBIndex.zig");
const IDBCursor = @import("IDBCursor.zig");
const IDBRequest = @import("IDBRequest.zig");
const IDBKeyRange = @import("IDBKeyRange.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const DOMStringList = @import("../../collections.zig").DOMStringList;

const log = lp.log;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

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

    self.deleteBounds(bounds) catch |err| {
        log.warn(.storage, "idb delete", .{ .err = err });
        request.setError(err);
    };
    return request;
}

fn deleteBounds(self: *IDBObjectStore, bounds: Engine.Bounds) !void {
    try self._engine.deleteIndexRecordsForRange(self._store_id, bounds);
    try self._engine.deleteRange(self._store_id, bounds);
}

pub fn clear(self: *IDBObjectStore, _: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.ensureBegun();

    const request = try txn.newRequest();
    self.clearAll() catch |err| {
        log.warn(.storage, "idb clear", .{ .err = err });
        request.setError(err);
    };
    return request;
}

fn clearAll(self: *IDBObjectStore) !void {
    try self._engine.clearIndexRecordsForStore(self._store_id);
    try self._engine.clear(self._store_id);
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
    return self._getAll(query, count_, .value, exec);
}

fn _getAll(self: *IDBObjectStore, query: ?js.Value, count_: ?u32, column: Engine.Column, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    const bounds = try IDBKeyRange.resolveQuery(exec.call_arena, query, exec);
    const request = try txn.newRequest();

    const arr = self.collectAll(exec, bounds, column, count_) catch |err| {
        log.warn(.storage, "idb getAll", .{ .err = err });
        request.setError(err);
        return request;
    };
    try request.setValue(arr);
    return request;
}

// Stream a getAll/getAllKeys result straight into a JS array: .value rows
// deserialize, .key rows decode — nothing is copied out of sqlite first.
fn collectAll(self: *IDBObjectStore, exec: *Execution, bounds: Engine.Bounds, column: Engine.Column, count_: ?u32) !js.Value {
    const local = exec.js.local.?;
    const arena = exec.call_arena;

    var rows = try self._engine.getAllRangeRows(self._store_id, bounds, column, count_);
    defer rows.deinit();

    const arr = local.newArray(0);
    var i: u32 = 0;
    while (try rows.next()) |row| {
        const bytes = row.get([]const u8, 0);
        const value = if (column == .value) try js.Value.deserialize(local, bytes) else try Key.decodeToJs(arena, local, bytes);
        _ = try arr.set(i, value, .{});
        i += 1;
    }
    return arr.toValue();
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
    return self._getAll(query, count_, .key, exec);
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

    // Record + index rows are atomic: a unique-index violation rolls the record
    // write back too.
    try self._engine.savepoint();
    self.writeRecord(kind, encoded, serialized.bytes(), value, exec) catch |err| {
        self._engine.rollbackSavepoint();
        log.warn(.storage, "idb write", .{ .err = err, .kind = kind });
        request.setError(err);
        return request;
    };
    try self._engine.releaseSavepoint();

    try request.setValue(key_value);
    return request;
}

fn writeRecord(self: *IDBObjectStore, kind: WriteKind, key: []const u8, bytes: []const u8, value: js.Value, exec: *Execution) !void {
    switch (kind) {
        .add => try self._engine.add(self._store_id, key, bytes),
        .put => try self._engine.put(self._store_id, key, bytes),
    }
    try self.reindex(value, key, exec);
}

// Used by IDBCursor.update: overwrite the record at `key` and re-index, atomically.
pub fn writeAt(self: *IDBObjectStore, key: []const u8, value: js.Value, bytes: []const u8, exec: *Execution) !void {
    try self._engine.savepoint();
    errdefer self._engine.rollbackSavepoint();

    try self._engine.put(self._store_id, key, bytes);
    try self.reindex(value, key, exec);

    try self._engine.releaseSavepoint();
}

// Used by IDBCursor.delete: drop the record at `key` and its index entries.
pub fn deleteAt(self: *IDBObjectStore, key: []const u8) !void {
    try self._engine.deleteIndexRecordsForKey(self._store_id, key);
    try self._engine.deleteRange(self._store_id, Engine.Bounds.point(key));
}

// Drop a record's old index entries and add fresh ones from `value`.
fn reindex(self: *IDBObjectStore, value: js.Value, primary_key: []const u8, exec: *Execution) !void {
    const arena = exec.call_arena;
    const indexes = try self._engine.indexesForStore(arena, self._store_id);
    if (indexes.len == 0) {
        return;
    }

    var seen: std.ArrayList([]const u8) = .empty;
    try self._engine.deleteIndexRecordsForKey(self._store_id, primary_key);
    for (indexes) |idx| {
        try self.addIndexEntries(arena, &seen, idx.id, idx.unique, idx.multi_entry, idx.key_path, value, primary_key);
    }
}

fn addIndexEntries(self: *IDBObjectStore, arena: Allocator, seen: *std.ArrayList([]const u8), index_id: i64, unique: bool, multi_entry: bool, key_path: []const u8, value: js.Value, primary_key: []const u8) !void {
    const extracted = Key.evaluatePath(value, key_path) orelse return;
    if (multi_entry and extracted.isArray()) {
        seen.clearRetainingCapacity();

        // every value of an array is added, but only once (e.g. deduplicated)
        const arr = extracted.toArray();
        for (0..arr.len()) |i| {
            const element = try arr.get(@intCast(i));
            const encoded = Key.encodeValue(arena, element) catch continue; // skip invalid elements
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, encoded)) {
                    continue;
                }
            }
            try seen.append(arena, encoded);
            try self._engine.addIndexRecord(index_id, encoded, primary_key, unique);
        }
    } else {
        const encoded = Key.encodeValue(arena, extracted) catch return; // not a valid key -> not indexed
        try self._engine.addIndexRecord(index_id, encoded, primary_key, unique);
    }
}

const CreateIndexOptions = struct {
    unique: bool = false,
    multiEntry: bool = false,
};

// Only callable during an upgrade (versionchange transaction).
pub fn createIndex(self: *IDBObjectStore, name: []const u8, key_path: []const u8, options: ?CreateIndexOptions, exec: *Execution) !*IDBIndex {
    const txn = self._txn orelse return error.InvalidStateError;
    if (txn._mode != .versionchange) {
        return error.InvalidStateError;
    }
    const opts = options orelse CreateIndexOptions{};

    try self._engine.savepoint();
    errdefer self._engine.rollbackSavepoint();

    const index_id = self._engine.createIndexRow(self._store_id, name, key_path, opts.unique, opts.multiEntry) catch |err| switch (err) {
        error.Constraint => return error.ConstraintError, // duplicate index name
        else => return err,
    };

    const arena = exec.call_arena;
    const local = exec.js.local.?;

    {
        // we reach directly in to _engine.conn here to avoid copying the values out
        // sqlite
        var rows = try self._engine.conn.rows("select key, value from idb_records where object_store_id = ?1", .{self._store_id});
        defer rows.deinit();

        var seen: std.ArrayList([]const u8) = .empty;
        while (try rows.next()) |row| {
            const value = try js.Value.deserialize(local, row.get([]const u8, 1));
            try self.addIndexEntries(arena, &seen, index_id, opts.unique, opts.multiEntry, key_path, value, row.get([]const u8, 0));
        }
    }

    const owned_name = try exec.dupeString(name);
    const owned_key_path = try exec.dupeString(key_path);
    const idb_index = try IDBIndex.init(self, .{
        .id = index_id,
        .key_path = owned_key_path,
        .unique = opts.unique,
        .multi_entry = opts.multiEntry,
    }, owned_name, exec);
    try self._engine.releaseSavepoint();
    return idb_index;
}

// Only callable during an upgrade (versionchange transaction).
pub fn deleteIndex(self: *IDBObjectStore, name: []const u8, _: *Execution) !void {
    const txn = self._txn orelse return error.InvalidStateError;
    if (txn._mode != .versionchange) {
        return error.InvalidStateError;
    }
    self._engine.deleteIndexRow(self._store_id, name) catch |err| switch (err) {
        error.NotFound => return error.NotFoundError,
        else => return err,
    };
}

pub fn index(self: *IDBObjectStore, name: []const u8, exec: *Execution) !*IDBIndex {
    if (self._txn == null) {
        return error.InvalidStateError;
    }
    const info = (try self._engine.indexInfo(exec.arena, self._store_id, name)) orelse return error.NotFound;
    const owned_name = try exec.dupeString(name);
    return IDBIndex.init(self, info, owned_name, exec);
}

pub fn getIndexNames(self: *IDBObjectStore, exec: *Execution) !*DOMStringList {
    const arena = try exec.getArena(.small, "IDB.getIndexNames");
    errdefer exec.releaseArena(arena);

    const names = try self._engine.indexNames(arena, self._store_id);
    const list = try arena.create(DOMStringList);
    list.* = .{ ._items = names, ._arena = arena };
    return list;
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
    pub const indexNames = bridge.accessor(IDBObjectStore.getIndexNames, null, .{});
    pub const createIndex = bridge.function(IDBObjectStore.createIndex, .{ });
    pub const deleteIndex = bridge.function(IDBObjectStore.deleteIndex, .{ });
    pub const index = bridge.function(IDBObjectStore.index, .{ });
};
