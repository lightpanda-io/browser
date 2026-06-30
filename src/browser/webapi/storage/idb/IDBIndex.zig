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
const IDBCursor = @import("IDBCursor.zig");
const IDBRequest = @import("IDBRequest.zig");
const IDBKeyRange = @import("IDBKeyRange.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");

const log = lp.log;
const Execution = js.Execution;

const IDBIndex = @This();

_store: *IDBObjectStore,
_engine: *Engine,
_index_id: i64,
_name: []const u8,
_key_path: []const u8,
_unique: bool,
_multi_entry: bool,

pub fn init(obj_store: *IDBObjectStore, info: Engine.IndexInfo, name: []const u8, exec: *Execution) !*IDBIndex {
    return exec._factory.create(IDBIndex{
        ._store = obj_store,
        ._engine = obj_store._engine,
        ._index_id = info.id,
        ._name = name,
        ._key_path = info.key_path,
        ._unique = info.unique,
        ._multi_entry = info.multi_entry,
    });
}

fn txn(self: *IDBIndex) !*IDBTransaction {
    const t = self._store._txn orelse return error.TransactionInactiveError;
    try t.ensureBegun();
    return t;
}

pub fn get(self: *IDBIndex, query: js.Value, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const arena = exec.call_arena;
    const bounds = try IDBKeyRange.resolveQuery(arena, query, exec);
    const request = try t.newRequest();

    const bytes = self._engine.indexGetRange(arena, self._store._store_id, self._index_id, bounds) catch |err| {
        log.warn(.storage, "idb index get", .{ .err = err });
        request.setError(err);
        return request;
    };

    const b = bytes orelse return request;
    try request.setValue(try js.Value.deserialize(exec.js.local.?, b));
    return request;
}

pub fn getKey(self: *IDBIndex, query: js.Value, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const arena = exec.call_arena;
    const bounds = try IDBKeyRange.resolveQuery(arena, query, exec);
    const request = try t.newRequest();

    const bytes = self._engine.indexGetKeyRange(arena, self._index_id, bounds) catch |err| {
        log.warn(.storage, "idb index getKey", .{ .err = err });
        request.setError(err);
        return request;
    };
    const b = bytes orelse return request;
    try request.setValue(try Key.decodeToJs(arena, exec.js.local.?, b));
    return request;
}

pub fn getAll(self: *IDBIndex, query: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    return self._getAll(query, count_, .value, exec);
}

pub fn getAllKeys(self: *IDBIndex, query: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    return self._getAll(query, count_, .key, exec);
}

fn _getAll(self: *IDBIndex, query: ?js.Value, count_: ?u32, column: Engine.Column, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const bounds = try IDBKeyRange.resolveQuery(exec.call_arena, query, exec);
    const request = try t.newRequest();

    const arr = self.collectAll(bounds, count_, column, exec) catch |err| {
        log.warn(.storage, "idb index getAll", .{ .err = err });
        request.setError(err);
        return request;
    };
    try request.setValue(arr);
    return request;
}

// Stream an index getAll/getAllKeys straight into a JS array: .value rows are
// the joined records (deserialized), .key rows are primary keys (decoded).
fn collectAll(self: *IDBIndex, bounds: Engine.Bounds, count_: ?u32, column: Engine.Column, exec: *Execution) !js.Value {
    const local = exec.js.local.?;
    const arena = exec.call_arena;

    var rows = try self._engine.indexGetAllRangeRows(self._store._store_id, self._index_id, bounds, column, count_);
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

pub fn count(self: *IDBIndex, query: ?js.Value, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const bounds = try IDBKeyRange.resolveQuery(exec.call_arena, query, exec);
    const request = try t.newRequest();

    const n = self._engine.indexCountRange(self._index_id, bounds) catch |err| {
        log.warn(.storage, "idb index count", .{ .err = err });
        request.setError(err);
        return request;
    };
    try request.setValue(try exec.js.local.?.zigValueToJs(n, .{}));
    return request;
}

pub fn openCursor(self: *IDBIndex, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    const bounds = try IDBKeyRange.resolveQuery(exec.arena, query, exec);
    return IDBCursor.openIndex(self, bounds, direction orelse .next, false, exec);
}

pub fn openKeyCursor(self: *IDBIndex, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    const bounds = try IDBKeyRange.resolveQuery(exec.arena, query, exec);
    return IDBCursor.openIndex(self, bounds, direction orelse .next, true, exec);
}

pub fn getName(self: *const IDBIndex) []const u8 {
    return self._name;
}

pub fn getKeyPath(self: *const IDBIndex) []const u8 {
    return self._key_path;
}

pub fn getUnique(self: *const IDBIndex) bool {
    return self._unique;
}

pub fn getMultiEntry(self: *const IDBIndex) bool {
    return self._multi_entry;
}

pub fn getObjectStore(self: *IDBIndex) *IDBObjectStore {
    return self._store;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBIndex);

    pub const Meta = struct {
        pub const name = "IDBIndex";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(IDBIndex.getName, null, .{});
    pub const keyPath = bridge.accessor(IDBIndex.getKeyPath, null, .{});
    pub const unique = bridge.accessor(IDBIndex.getUnique, null, .{});
    pub const multiEntry = bridge.accessor(IDBIndex.getMultiEntry, null, .{});
    pub const objectStore = bridge.accessor(IDBIndex.getObjectStore, null, .{});
    pub const get = bridge.function(IDBIndex.get, .{ .dom_exception = true });
    pub const getKey = bridge.function(IDBIndex.getKey, .{ .dom_exception = true });
    pub const getAll = bridge.function(IDBIndex.getAll, .{ .dom_exception = true });
    pub const getAllKeys = bridge.function(IDBIndex.getAllKeys, .{ .dom_exception = true });
    pub const count = bridge.function(IDBIndex.count, .{ .dom_exception = true });
    pub const openCursor = bridge.function(IDBIndex.openCursor, .{ .dom_exception = true });
    pub const openKeyCursor = bridge.function(IDBIndex.openKeyCursor, .{ .dom_exception = true });
};
