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
const IDBRequest = @import("IDBRequest.zig");
const IDBTransaction = @import("IDBTransaction.zig");

const log = lp.log;
const Execution = js.Execution;

const IDBObjectStore = @This();

_exec: *Execution,
_engine: *Engine,
_store_id: i64,
_name: []const u8,
_key_path: ?[]const u8,
// only null during an upgradeneeded
_txn: ?*IDBTransaction,

pub fn init(
    engine: *Engine,
    txn: ?*IDBTransaction,
    store_id: i64,
    name: []const u8,
    key_path: ?[]const u8,
    exec: *Execution,
) !*IDBObjectStore {
    return exec._factory.create(IDBObjectStore{
        ._exec = exec,
        ._engine = engine,
        ._txn = txn,
        ._store_id = store_id,
        ._name = name,
        ._key_path = key_path,
    });
}

pub fn add(self: *IDBObjectStore, value: js.Value, key: ?js.Value) !*IDBRequest {
    return self.write(value, key, .add);
}

pub fn put(self: *IDBObjectStore, value: js.Value, key: ?js.Value) !*IDBRequest {
    return self.write(value, key, .put);
}

pub fn get(self: *IDBObjectStore, key: js.Value, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    // Both the encoded key and the fetched bytes are consumed within this call
    // (the bytes are deserialized below), so the per-call scratch arena suffices.
    const arena = exec.call_arena;
    const encoded = try Key.encodeValue(key, arena);
    const request = try txn.newRequest();

    const bytes = self._engine.get(arena, self._store_id, encoded) catch |err| {
        log.warn(.storage, "idb get", .{ .err = err });
        request.setError(err);
        return request;
    };

    const b = bytes orelse return request;

    const value = try js.Value.deserialize(exec.js.local.?, b);
    try request.setValueResult(value);
    return request;
}

pub fn delete(self: *IDBObjectStore, key: js.Value, _: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.ensureBegun();

    const encoded = try Key.encodeValue(key, self._exec.call_arena);
    const request = try txn.newRequest();

    self._engine.delete(self._store_id, encoded) catch |err| {
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

pub fn count(self: *IDBObjectStore, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    const request = try txn.newRequest();
    const n = self._engine.count(self._store_id) catch |err| {
        log.warn(.storage, "idb count", .{ .err = err });
        request.setError(err);
        return request;
    };
    try request.setValueResult(try exec.js.local.?.zigValueToJs(n, .{}));
    return request;
}

pub fn getAll(self: *IDBObjectStore, exec: *Execution) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    try txn.ensureBegun();

    const local = exec.js.local.?;
    const request = try txn.newRequest();

    const values = self._engine.getAll(exec.call_arena, self._store_id) catch |err| {
        log.warn(.storage, "idb getAll", .{ .err = err });
        request.setError(err);
        return request;
    };

    const arr = local.newArray(@intCast(values.len));
    for (values, 0..) |bytes, i| {
        const value = try js.Value.deserialize(local, bytes);
        _ = try arr.set(@intCast(i), value, .{});
    }
    try request.setValueResult(arr.toValue());
    return request;
}

pub fn getName(self: *const IDBObjectStore) []const u8 {
    return self._name;
}

pub fn getKeyPath(self: *const IDBObjectStore) ?[]const u8 {
    return self._key_path;
}

const WriteKind = enum { add, put };

fn write(self: *IDBObjectStore, value: js.Value, key_: ?js.Value, kind: WriteKind) !*IDBRequest {
    const txn = self._txn orelse return error.TransactionInactiveError;
    if (txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    try txn.ensureBegun();

    const key = key_ orelse return error.DataError;
    const encoded = try Key.encodeValue(key, self._exec.call_arena);

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

    try request.setValueResult(key);
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
    pub const add = bridge.function(IDBObjectStore.add, .{ .dom_exception = true });
    pub const put = bridge.function(IDBObjectStore.put, .{ .dom_exception = true });
    pub const get = bridge.function(IDBObjectStore.get, .{ .dom_exception = true });
    pub const delete = bridge.function(IDBObjectStore.delete, .{ .dom_exception = true });
    pub const clear = bridge.function(IDBObjectStore.clear, .{ .dom_exception = true });
    pub const count = bridge.function(IDBObjectStore.count, .{ .dom_exception = true });
    pub const getAll = bridge.function(IDBObjectStore.getAll, .{ .dom_exception = true });
};
