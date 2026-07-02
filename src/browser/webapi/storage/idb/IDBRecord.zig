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

const js = @import("../../../js/js.zig");

const Page = @import("../../../Page.zig");
const Key = @import("Key.zig");
const IDBTransaction = @import("IDBTransaction.zig");

const Execution = js.Execution;

const IDBRecord = @This();

// A single result of getAllRecords: the (index or store) key, the primary/store
// key, and the value. Stored encoded/serialized and decoded lazily on access
// (mirroring IDBKeyRange). Record and bytes live on the transaction's arena;
_txn: *IDBTransaction,
_key: []const u8,
_primary_key: []const u8,
_value: []const u8,

pub fn acquireRef(self: *IDBRecord) void {
    self._txn.acquireRef();
}

pub fn releaseRef(self: *IDBRecord, page: *Page) void {
    self._txn.releaseRef(page);
}

// Build a record from borrowed bytes — duped onto the transaction's arena so
// the record outlives this call — and return its JS value.
pub fn initValue(txn: *IDBTransaction, local: *const js.Local, key: []const u8, primary_key: []const u8, value: []const u8) !js.Value {
    const arena = txn._arena;
    const record = try arena.create(IDBRecord);
    record.* = .{
        ._txn = txn,
        ._key = try arena.dupe(u8, key),
        ._primary_key = try arena.dupe(u8, primary_key),
        ._value = try arena.dupe(u8, value),
    };
    return local.zigValueToJs(record, .{});
}

pub fn getKey(self: *const IDBRecord, exec: *Execution) !js.Value {
    return Key.decodeToJs(exec.call_arena, exec.js.local.?, self._key);
}

pub fn getPrimaryKey(self: *const IDBRecord, exec: *Execution) !js.Value {
    return Key.decodeToJs(exec.call_arena, exec.js.local.?, self._primary_key);
}

pub fn getValue(self: *const IDBRecord, exec: *Execution) !js.Value {
    return js.Value.deserialize(exec.js.local.?, self._value);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBRecord);

    pub const Meta = struct {
        pub const name = "IDBRecord";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const key = bridge.accessor(IDBRecord.getKey, null, .{});
    pub const primaryKey = bridge.accessor(IDBRecord.getPrimaryKey, null, .{});
    pub const value = bridge.accessor(IDBRecord.getValue, null, .{});
};
