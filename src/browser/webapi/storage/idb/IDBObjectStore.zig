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

const Page = @import("../../../Page.zig");
const idb = @import("idb.zig");
const Key = @import("Key.zig");
const Engine = @import("Engine.zig");
const IDBIndex = @import("IDBIndex.zig");
const IDBCursor = @import("IDBCursor.zig");
const IDBRecord = @import("IDBRecord.zig");
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
_key_path: ?Key.KeyPath,
_auto_increment: bool,
_txn: *IDBTransaction,
_deleted: bool = false,
// Created by this (versionchange) transaction — so an abort must delete it.
_created: bool = false,
// identity map, store.indexes('a') === store.index('a')
_indexes: std.ArrayList(*IDBIndex) = .empty,
// not just for efficiency, we must return the same v8::Array every time the
// compound key is accessed.
_key_path_js: ?*js.Value.BareGlobal = null,

pub fn init(
    txn: *IDBTransaction,
    store_id: i64,
    name: []const u8,
    key_path: ?Key.KeyPath,
    auto_increment: bool,
) !*IDBObjectStore {
    const self = try txn._arena.create(IDBObjectStore);
    self.* = .{
        ._txn = txn,
        ._name = name,
        ._engine = txn._engine,
        ._store_id = store_id,
        ._key_path = key_path,
        ._auto_increment = auto_increment,
    };
    return self;
}

pub fn acquireRef(self: *IDBObjectStore) void {
    self._txn.acquireRef();
}

pub fn releaseRef(self: *IDBObjectStore, page: *Page) void {
    self._txn.releaseRef(page);
}

pub fn add(self: *IDBObjectStore, value: js.Value, key: ?js.Value, exec: *Execution) !*IDBRequest {
    return self.write(value, key, .add, exec);
}

pub fn put(self: *IDBObjectStore, value: js.Value, key: ?js.Value, exec: *Execution) !*IDBRequest {
    return self.write(value, key, .put, exec);
}

pub fn get(self: *IDBObjectStore, query: js.Value, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    try txn.assertActive();
    const bounds = try IDBKeyRange.resolveKey(txn._arena, query, exec);
    const request = try txn.newRequest();
    return request.submit(.{ .store_get = .{ .store = self, .bounds = bounds } }, exec);
}

pub fn runGet(self: *IDBObjectStore, request: *IDBRequest, bounds: Engine.Bounds, exec: *Execution) !void {
    const arena = exec.call_arena;
    const bytes = self._engine.getRange(arena, self._store_id, bounds) catch |err| {
        log.warn(.storage, "idb get", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    const b = bytes orelse return; // no record -> undefined
    try request.setValue(try js.Value.deserialize(exec.js.local.?, b));
}

pub fn delete(self: *IDBObjectStore, query: js.Value, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.assertActive();
    const bounds = try IDBKeyRange.resolveKey(txn._arena, query, exec);
    const request = try txn.newRequest();
    return request.submit(.{ .store_delete = .{ .store = self, .bounds = bounds } }, exec);
}

pub fn runDelete(self: *IDBObjectStore, request: *IDBRequest, bounds: Engine.Bounds, _: *Execution) !void {
    self.deleteBounds(bounds) catch |err| {
        log.warn(.storage, "idb delete", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
    };
}

fn deleteBounds(self: *IDBObjectStore, bounds: Engine.Bounds) !void {
    try self._engine.deleteIndexRecordsForRange(self._store_id, bounds);
    try self._engine.deleteRange(self._store_id, bounds);
}

pub fn clear(self: *IDBObjectStore, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.assertActive();
    const request = try txn.newRequest();
    return request.submit(.{ .store_clear = self }, exec);
}

pub fn runClear(self: *IDBObjectStore, request: *IDBRequest, _: *Execution) !void {
    self.clearAll() catch |err| {
        log.warn(.storage, "idb clear", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
    };
}

fn clearAll(self: *IDBObjectStore) !void {
    try self._engine.clearIndexRecordsForStore(self._store_id);
    try self._engine.clear(self._store_id);
}

pub fn count(self: *IDBObjectStore, query: ?js.Value, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    try txn.assertActive();
    const bounds = try IDBKeyRange.resolveQuery(txn._arena, query, exec);
    const request = try txn.newRequest();
    return request.submit(.{ .store_count = .{ .store = self, .bounds = bounds } }, exec);
}

pub fn runCount(self: *IDBObjectStore, request: *IDBRequest, bounds: Engine.Bounds, exec: *Execution) !void {
    const n = self._engine.countRange(self._store_id, bounds) catch |err| {
        log.warn(.storage, "idb count", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    try request.setValue(try exec.js.local.?.zigValueToJs(n, .{}));
}

// What a getAll/getAllKeys/getAllRecords produces
pub const GetAllMode = enum { value, key, record };

pub fn getAll(self: *IDBObjectStore, query_or_options: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    return self._getAll(query_or_options, count_, .value, exec);
}

pub fn getAllKeys(self: *IDBObjectStore, query_or_options: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    return self._getAll(query_or_options, count_, .key, exec);
}

pub fn getAllRecords(self: *IDBObjectStore, options: ?js.Value, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    try txn.assertActive();
    const args = try IDBKeyRange.resolveGetAllOptions(txn._arena, options, exec);
    const request = try txn.newRequest();
    return request.submit(.{ .store_get_all = .{ .store = self, .args = args, .mode = .record } }, exec);
}

fn _getAll(self: *IDBObjectStore, query_or_options: ?js.Value, count_: ?u32, mode: GetAllMode, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    try txn.assertActive();
    const args = try IDBKeyRange.resolveGetAll(txn._arena, query_or_options, count_, exec);
    const request = try txn.newRequest();
    return request.submit(.{ .store_get_all = .{ .store = self, .args = args, .mode = mode } }, exec);
}

pub fn runGetAll(self: *IDBObjectStore, request: *IDBRequest, args: IDBKeyRange.GetAllArgs, mode: GetAllMode, exec: *Execution) !void {
    const arr = self.collectAll(exec, args, mode) catch |err| {
        log.warn(.storage, "idb getAll", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    try request.setValue(arr);
}

fn collectAll(self: *IDBObjectStore, exec: *Execution, args: IDBKeyRange.GetAllArgs, mode: GetAllMode) !js.Value {
    const local = exec.js.local.?;
    // A store's primary keys are unique, so nextunique/prevunique are just
    // next/prev here — no de-duplication needed. For an object store the key is the
    // primary key.
    const reverse = args.direction == .prev or args.direction == .prevunique;

    var rows = try self._engine.getAllRows(self._store_id, args.bounds, reverse, args.count);
    defer rows.deinit();

    const arr = local.newArray(0);
    var i: u32 = 0;
    while (try rows.next()) |row| {
        const key = row.get([]const u8, 0);
        const out: js.Value = switch (mode) {
            .value => try js.Value.deserialize(local, row.get([]const u8, 1)),
            .key => try Key.decodeToJs(exec.call_arena, local, key),
            .record => try IDBRecord.initValue(self._txn, local, key, key, row.get([]const u8, 1)),
        };
        _ = try arr.set(i, out, .{});
        i += 1;
    }
    return arr.toValue();
}

pub fn getKey(self: *IDBObjectStore, query: js.Value, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    try txn.assertActive();
    const bounds = try IDBKeyRange.resolveKey(txn._arena, query, exec);
    const request = try txn.newRequest();
    return request.submit(.{ .store_get_key = .{ .store = self, .bounds = bounds } }, exec);
}

pub fn runGetKey(self: *IDBObjectStore, request: *IDBRequest, bounds: Engine.Bounds, exec: *Execution) !void {
    const arena = exec.call_arena;
    const found = self._engine.getKeyRange(arena, self._store_id, bounds) catch |err| {
        log.warn(.storage, "idb getKey", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    const bytes = found orelse return; // no record -> undefined
    try request.setValue(try Key.decodeToJs(arena, exec.js.local.?, bytes));
}

pub fn openCursor(self: *IDBObjectStore, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const bounds = try IDBKeyRange.resolveQuery(self._txn._arena, query, exec);
    return IDBCursor.init(self, bounds, direction orelse .next, false, exec);
}

pub fn openKeyCursor(self: *IDBObjectStore, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const bounds = try IDBKeyRange.resolveQuery(self._txn._arena, query, exec);
    return IDBCursor.init(self, bounds, direction orelse .next, true, exec);
}

pub fn getName(self: *const IDBObjectStore) []const u8 {
    return self._name;
}

pub fn getKeyPath(self: *IDBObjectStore, exec: *Execution) !js.Value {
    return idb.cachedKeyPathJs(&self._key_path_js, self._txn, self._key_path, exec);
}

pub fn getAutoIncrement(self: *const IDBObjectStore) bool {
    return self._auto_increment;
}

pub fn getTransaction(self: *IDBObjectStore) *IDBTransaction {
    return self._txn;
}

pub const WriteKind = enum { add, put };

// The key that we're writing to. We need to validate this on the request side
// so we might as well store the result for the execution side.
pub const PreparedKey = union(enum) {
    // generate number key + injsect into value
    generate_in_line,

    // generate number key, don't inject
    generate_out_of_line,

    // an explicit key, could be passed in or extracted from the value
    explicit: struct { encoded: []const u8, bump: ?f64 },
};

fn write(self: *IDBObjectStore, value: js.Value, key_arg: ?js.Value, kind: WriteKind, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const txn = self._txn;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.assertActive();

    // Resolve (and validate) the key now, so DataError / a throwing key getter
    // throws synchronously. Encoded key bytes are captured on the transaction's
    // arena to outlive this call. The record write itself is deferred to runWrite.
    const prepared: PreparedKey = blk: {
        if (self._key_path) |kp| {
            if (key_arg != null) {
                // can't have an explicit key if we're configured for in-line keys
                return error.DataError;
            }
            if (try Key.extractKeyPath(exec.js.local.?, value, kp)) |extracted| {
                break :blk .{ .explicit = .{
                    .encoded = try Key.encodeValue(txn._arena, extracted),
                    .bump = if (self._auto_increment and extracted.isNumber()) try extracted.toF64() else null,
                } };
            }
            // The keypath wasn't in the value...
            if (self._auto_increment == false) {
                return error.DataError;
            }
            // A compound or empty key path can't carry a generated key, so
            // auto_increment implies a non-empty single-property path here.
            if (Key.canInjectKey(value, kp.string) == false) {
                return error.DataError;
            }
            break :blk .generate_in_line;
        }

        // Out-of-line keys.
        if (key_arg) |k| {
            break :blk .{ .explicit = .{
                .encoded = try Key.encodeValue(txn._arena, k),
                .bump = if (self._auto_increment and k.isNumber()) try k.toF64() else null,
            } };
        }
        if (self._auto_increment == false) {
            return error.DataError;
        }
        break :blk .generate_out_of_line;
    };

    const request = try txn.newRequest();
    const value_global = try txn.persist(value);
    return request.submit(.{ .store_write = .{
        .store = self,
        .kind = kind,
        .value = value_global,
        .key = prepared,
    } }, exec);
}

pub fn runWrite(self: *IDBObjectStore, request: *IDBRequest, kind: WriteKind, value_global: *js.Value.BareGlobal, prepared: PreparedKey, exec: *Execution) !void {
    // Written (or failed) is written: the pinned value is dead once this op
    // ran, so release its handle now instead of at transaction teardown.
    defer value_global.deinit();
    self.writeInner(request, kind, value_global, prepared, exec) catch |err| {
        if (err != error.Constraint) {
            log.warn(.storage, "idb write", .{ .err = err, .kind = kind, .sqlite = self._engine.lastError() });
        }
        request.setError(err);
    };
}

fn writeInner(self: *IDBObjectStore, request: *IDBRequest, kind: WriteKind, value_global: *js.Value.BareGlobal, prepared: PreparedKey, exec: *Execution) !void {
    const local = exec.js.local.?;
    const value = value_global.local(local);

    // Resolve the encoded key + the JS value that becomes the request result. For
    // generated keys, that's where the connection is finally touched.
    const encoded: []const u8 = switch (prepared) {
        .explicit => |e| blk: {
            if (e.bump) |b| {
                try self._engine.maybeBumpGenerator(self._store_id, b);
            }
            break :blk e.encoded;
        },
        .generate_out_of_line => blk: {
            const n = try self._engine.nextGeneratedKey(self._store_id);
            break :blk try Key.encodeValue(exec.call_arena, try local.newNumber(@floatFromInt(n)));
        },
        .generate_in_line => blk: {
            const n = try self._engine.nextGeneratedKey(self._store_id);
            const k = try local.newNumber(@floatFromInt(n));
            try Key.injectKey(local, value, self._key_path.?.string, k);
            break :blk try Key.encodeValue(exec.call_arena, k);
        },
    };

    const serialized = try value.serialize();
    defer serialized.deinit();

    // Record + index rows are atomic: a unique-index violation rolls the record
    // write back too.
    try self._engine.savepoint();
    self.writeRecord(kind, encoded, serialized.bytes(), value, exec) catch |err| {
        self._engine.rollbackSavepoint();
        return err;
    };
    try self._engine.releaseSavepoint();

    // The request result is the record's key (decoded back from the encoded bytes).
    try request.setValue(try Key.decodeToJs(exec.call_arena, local, encoded));
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
        try self.addIndexEntries(exec.js.local.?, arena, &seen, idx.id, idx.unique, idx.multi_entry, idx.key_path, value, primary_key);
    }
}

fn addIndexEntries(self: *IDBObjectStore, local: *const js.Local, arena: Allocator, seen: *std.ArrayList([]const u8), index_id: i64, unique: bool, multi_entry: bool, key_path: Key.KeyPath, value: js.Value, primary_key: []const u8) !void {
    const extracted = (try Key.extractKeyPath(local, value, key_path)) orelse return;
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
pub fn createIndex(self: *IDBObjectStore, name: []const u8, key_path: Key.KeyPath, options: ?CreateIndexOptions, exec: *Execution) !*IDBIndex {
    try self.assertLive();
    const txn = self._txn;
    if (txn._mode != .versionchange) {
        return error.InvalidStateError;
    }
    // Spec order: the transaction-state check precedes the index-name check.
    try txn.assertActive();
    if (Key.isValidKeyPathSpec(key_path) == false) {
        return error.SyntaxError;
    }
    const opts = options orelse CreateIndexOptions{};
    // multiEntry is meaningless for a compound key path.
    if (opts.multiEntry and std.meta.activeTag(key_path) == .list) {
        return error.InvalidAccessError;
    }

    const owned_key_path = try Key.dupeKeyPath(txn._arena, key_path);

    try self._engine.savepoint();
    errdefer self._engine.rollbackSavepoint();

    const index_id = self._engine.createIndexRow(txn._arena, self._store_id, name, owned_key_path, opts.unique, opts.multiEntry) catch |err| switch (err) {
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
            try self.addIndexEntries(local, arena, &seen, index_id, opts.unique, opts.multiEntry, owned_key_path, value, row.get([]const u8, 0));
        }
    }

    const owned_name = try txn.dupe(name);
    const idb_index = try IDBIndex.init(self, .{
        .id = index_id,
        .key_path = owned_key_path,
        .unique = opts.unique,
        .multi_entry = opts.multiEntry,
    }, owned_name);
    idb_index._created = true;
    try self._engine.releaseSavepoint();
    try self._indexes.append(txn._arena, idb_index);
    return idb_index;
}

// Only callable during an upgrade (versionchange transaction).
pub fn deleteIndex(self: *IDBObjectStore, name: []const u8, _: *Execution) !void {
    try self.assertLive();
    const txn = self._txn;
    if (txn._mode != .versionchange) {
        return error.InvalidStateError;
    }
    // Spec order: the transaction-state check precedes the index-name check.
    try txn.assertActive();
    self._engine.deleteIndexRow(self._store_id, name) catch |err| switch (err) {
        error.NotFound => return error.NotFoundError,
        else => return err,
    };
    for (self._indexes.items, 0..) |idx, i| {
        if (std.mem.eql(u8, idx._name, name)) {
            // A handle the caller still holds must report itself deleted.
            idx._deleted = true;
            _ = self._indexes.swapRemove(i);
            break;
        }
    }
}

pub fn index(self: *IDBObjectStore, name: []const u8, _: *Execution) !*IDBIndex {
    try self.assertLive();
    for (self._indexes.items) |idx| {
        if (std.mem.eql(u8, idx._name, name)) {
            return idx;
        }
    }

    const txn = self._txn;
    const info = (try self._engine.indexInfo(txn._arena, self._store_id, name)) orelse return error.NotFound;
    const owned_name = try txn.dupe(name);
    const idx = try IDBIndex.init(self, info, owned_name);
    try self._indexes.append(txn._arena, idx);
    return idx;
}

pub fn getIndexNames(self: *IDBObjectStore, exec: *Execution) !*DOMStringList {
    const arena = try exec.getArena(.small, "IDB.getIndexNames");
    errdefer exec.releaseArena(arena);

    const names = try self._engine.indexNames(arena, self._store_id);
    const list = try arena.create(DOMStringList);
    list.* = .{ ._items = names, ._arena = arena };
    return list;
}

fn assertLive(self: *const IDBObjectStore) !void {
    if (self._deleted) {
        return error.InvalidStateError;
    }
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
    pub const add = bridge.function(IDBObjectStore.add, .{});
    pub const put = bridge.function(IDBObjectStore.put, .{});
    pub const get = bridge.function(IDBObjectStore.get, .{});
    pub const getKey = bridge.function(IDBObjectStore.getKey, .{});
    pub const delete = bridge.function(IDBObjectStore.delete, .{});
    pub const clear = bridge.function(IDBObjectStore.clear, .{});
    pub const count = bridge.function(IDBObjectStore.count, .{});
    pub const getAll = bridge.function(IDBObjectStore.getAll, .{});
    pub const getAllKeys = bridge.function(IDBObjectStore.getAllKeys, .{});
    pub const getAllRecords = bridge.function(IDBObjectStore.getAllRecords, .{});
    pub const openCursor = bridge.function(IDBObjectStore.openCursor, .{});
    pub const openKeyCursor = bridge.function(IDBObjectStore.openKeyCursor, .{});
    pub const indexNames = bridge.accessor(IDBObjectStore.getIndexNames, null, .{});
    pub const createIndex = bridge.function(IDBObjectStore.createIndex, .{});
    pub const deleteIndex = bridge.function(IDBObjectStore.deleteIndex, .{});
    pub const index = bridge.function(IDBObjectStore.index, .{});
};
