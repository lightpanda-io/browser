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
const IDBCursor = @import("IDBCursor.zig");
const IDBRecord = @import("IDBRecord.zig");
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
_key_path: Key.KeyPath,
_unique: bool,
_multi_entry: bool,
_deleted: bool = false,
// Created by this (versionchange) transaction — so an abort must delete it.
_created: bool = false,
// not just for efficiency, we must return the same v8::Array every time the
// compound key is accessed.
_key_path_js: ?*js.Value.BareGlobal = null,

pub fn init(obj_store: *IDBObjectStore, info: Engine.IndexInfo, name: []const u8) !*IDBIndex {
    const self = try obj_store._txn._arena.create(IDBIndex);
    self.* = .{
        ._store = obj_store,
        ._engine = obj_store._engine,
        ._index_id = info.id,
        ._name = name,
        ._key_path = info.key_path,
        ._unique = info.unique,
        ._multi_entry = info.multi_entry,
    };
    return self;
}

pub fn acquireRef(self: *IDBIndex) void {
    self._store._txn.acquireRef();
}

pub fn releaseRef(self: *IDBIndex, page: *Page) void {
    self._store._txn.releaseRef(page);
}

// The index (or its object store) may have been deleted — including by an
// aborted upgrade. That check precedes the transaction-active check per spec.
fn assertLive(self: *const IDBIndex) !void {
    if (self._deleted or self._store._deleted) {
        return error.InvalidStateError;
    }
}

fn txn(self: *IDBIndex) !*IDBTransaction {
    try self.assertLive();
    const t = self._store._txn;
    try t.assertActive();
    return t;
}

pub fn get(self: *IDBIndex, query: js.Value, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const bounds = try IDBKeyRange.resolveKey(t._arena, query, exec);
    const request = try t.newRequest();
    return request.submit(.{ .index_get = .{ .index = self, .bounds = bounds } }, exec);
}

pub fn runGet(self: *IDBIndex, request: *IDBRequest, bounds: Engine.Bounds, exec: *Execution) !void {
    const arena = exec.call_arena;
    const bytes = self._engine.indexGetRange(arena, self._store._store_id, self._index_id, bounds) catch |err| {
        log.warn(.storage, "idb index get", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    const b = bytes orelse return;
    try request.setValue(try js.Value.deserialize(exec.js.local.?, b));
}

pub fn getKey(self: *IDBIndex, query: js.Value, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const bounds = try IDBKeyRange.resolveKey(t._arena, query, exec);
    const request = try t.newRequest();
    return request.submit(.{ .index_get_key = .{ .index = self, .bounds = bounds } }, exec);
}

pub fn runGetKey(self: *IDBIndex, request: *IDBRequest, bounds: Engine.Bounds, exec: *Execution) !void {
    const arena = exec.call_arena;
    const bytes = self._engine.indexGetKeyRange(arena, self._index_id, bounds) catch |err| {
        log.warn(.storage, "idb index getKey", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    const b = bytes orelse return;
    try request.setValue(try Key.decodeToJs(arena, exec.js.local.?, b));
}

pub fn getAll(self: *IDBIndex, query_or_options: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    return self._getAll(query_or_options, count_, .value, exec);
}

pub fn getAllKeys(self: *IDBIndex, query_or_options: ?js.Value, count_: ?u32, exec: *Execution) !*IDBRequest {
    return self._getAll(query_or_options, count_, .key, exec);
}

pub fn getAllRecords(self: *IDBIndex, options: ?js.Value, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const args = try IDBKeyRange.resolveGetAllOptions(t._arena, options, exec);
    const request = try t.newRequest();
    return request.submit(.{ .index_get_all = .{ .index = self, .args = args, .mode = .record } }, exec);
}

fn _getAll(self: *IDBIndex, query_or_options: ?js.Value, count_: ?u32, mode: IDBObjectStore.GetAllMode, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const args = try IDBKeyRange.resolveGetAll(t._arena, query_or_options, count_, exec);
    const request = try t.newRequest();
    return request.submit(.{ .index_get_all = .{ .index = self, .args = args, .mode = mode } }, exec);
}

pub fn runGetAll(self: *IDBIndex, request: *IDBRequest, args: IDBKeyRange.GetAllArgs, mode: IDBObjectStore.GetAllMode, exec: *Execution) !void {
    const arr = self.collectAll(args, mode, exec) catch |err| {
        log.warn(.storage, "idb index getAll", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    try request.setValue(arr);
}

// Build a JS array of an index result: for .value the joined record value; for .key
// the primary key; for .record the (index key, primary key, value) triple.
fn collectAll(self: *IDBIndex, args: IDBKeyRange.GetAllArgs, mode: IDBObjectStore.GetAllMode, exec: *Execution) !js.Value {
    const local = exec.js.local.?;
    const reverse = args.direction == .prev or args.direction == .prevunique;
    const unique = args.direction == .nextunique or args.direction == .prevunique;

    var rows = try self._engine.indexGetAllRows(self._store._store_id, self._index_id, args.bounds, reverse, unique, args.count);
    defer rows.deinit();

    const arr = local.newArray(0);
    var i: u32 = 0;
    while (try rows.next()) |row| {
        _ = try arr.set(i, try self.rowToValue(mode, row.get([]const u8, 0), row.get([]const u8, 1), row.get([]const u8, 2), exec), .{});
        i += 1;
    }
    return arr.toValue();
}

fn rowToValue(self: *IDBIndex, mode: IDBObjectStore.GetAllMode, key: []const u8, primary_key: []const u8, value: []const u8, exec: *Execution) !js.Value {
    const local = exec.js.local.?;
    return switch (mode) {
        .value => js.Value.deserialize(local, value),
        .key => Key.decodeToJs(exec.call_arena, local, primary_key),
        .record => IDBRecord.initValue(self._store._txn, local, key, primary_key, value),
    };
}

pub fn count(self: *IDBIndex, query: ?js.Value, exec: *Execution) !*IDBRequest {
    const t = try self.txn();
    const bounds = try IDBKeyRange.resolveQuery(t._arena, query, exec);
    const request = try t.newRequest();
    return request.submit(.{ .index_count = .{ .index = self, .bounds = bounds } }, exec);
}

pub fn runCount(self: *IDBIndex, request: *IDBRequest, bounds: Engine.Bounds, exec: *Execution) !void {
    const n = self._engine.indexCountRange(self._index_id, bounds) catch |err| {
        log.warn(.storage, "idb index count", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    try request.setValue(try exec.js.local.?.zigValueToJs(n, .{}));
}

pub fn openCursor(self: *IDBIndex, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const bounds = try IDBKeyRange.resolveQuery(self._store._txn._arena, query, exec);
    return IDBCursor.initIndex(self, bounds, direction orelse .next, false, exec);
}

pub fn openKeyCursor(self: *IDBIndex, query: ?js.Value, direction: ?IDBCursor.Direction, exec: *Execution) !*IDBRequest {
    try self.assertLive();
    const bounds = try IDBKeyRange.resolveQuery(self._store._txn._arena, query, exec);
    return IDBCursor.initIndex(self, bounds, direction orelse .next, true, exec);
}

pub fn getName(self: *const IDBIndex) []const u8 {
    return self._name;
}

pub fn getKeyPath(self: *IDBIndex, exec: *Execution) !js.Value {
    return idb.cachedKeyPathJs(&self._key_path_js, self._store._txn, self._key_path, exec);
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
    pub const get = bridge.function(IDBIndex.get, .{});
    pub const getKey = bridge.function(IDBIndex.getKey, .{});
    pub const getAll = bridge.function(IDBIndex.getAll, .{});
    pub const getAllKeys = bridge.function(IDBIndex.getAllKeys, .{});
    pub const getAllRecords = bridge.function(IDBIndex.getAllRecords, .{});
    pub const count = bridge.function(IDBIndex.count, .{});
    pub const openCursor = bridge.function(IDBIndex.openCursor, .{});
    pub const openKeyCursor = bridge.function(IDBIndex.openKeyCursor, .{});
};
