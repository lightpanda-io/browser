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
const IDBRequest = @import("IDBRequest.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const IDBCursorWithValue = @import("IDBCursorWithValue.zig");

const log = lp.log;
const Execution = js.Execution;

const IDBCursor = @This();

_engine: *Engine,
_store: *IDBObjectStore,
_txn: *IDBTransaction,
_request: *IDBRequest,
_bounds: Engine.Bounds,
_direction: Direction,
_key_only: bool,
_source: Source,
_got_value: bool = false,

// null for an object-store cursor
_index_id: ?i64 = null,

// the JS value of this Cursor, pre-converted and cached as an optimization
// since this cursor will be the request value on every iteration.
_js: js.Value.Global,

// Encoded current key; null before iteration and at the end. For an index cursor
// this is the index key; for an object store it equals the primary key.
_key: ?[]const u8 = null,

// Encoded primary (store) key. Equals _key for an object-store cursor.
_primary_key: ?[]const u8 = null,
// Current record's serialized value bytes (null when key-only or exhausted).
_value: ?[]const u8 = null,

pub const Direction = enum {
    next,
    nextunique,
    prev,
    prevunique,

    pub const js_enum_from_string = true;

    pub fn toString(self: Direction) []const u8 {
        return @tagName(self);
    }

    fn reverse(self: Direction) bool {
        return self == .prev or self == .prevunique;
    }
};

// What this cursor iterates — used only by the `source` accessor.
const Source = union(enum) {
    store: *IDBObjectStore,
    index: *IDBIndex,
};

// How the next iterate() positions the cursor.
const Seek = union(enum) {
    first, // start of the range, in the iteration direction
    next, // strictly past the current position
    to: []const u8, // continue(key): first record at/after an index/store key
    to_primary: struct { key: []const u8, primary_key: []const u8 }, // continuePrimaryKey
};

fn startSentinel(reverse: bool) []const u8 {
    return if (reverse) Engine.Bounds.max_sentinel else Engine.Bounds.min_sentinel;
}

// Cursor over an object store.
pub fn open(store: *IDBObjectStore, bounds: Engine.Bounds, direction: Direction, key_only: bool, exec: *Execution) !*IDBRequest {
    const txn = store._txn orelse return error.TransactionInactiveError;
    return create(store, txn, null, .{ .store = store }, bounds, direction, key_only, exec);
}

// Cursor over an index (key = index key, primaryKey = store key).
pub fn openIndex(index: *IDBIndex, bounds: Engine.Bounds, direction: Direction, key_only: bool, exec: *Execution) !*IDBRequest {
    const store = index._store;
    const txn = store._txn orelse return error.TransactionInactiveError;
    return create(store, txn, index._index_id, .{ .index = index }, bounds, direction, key_only, exec);
}

fn create(store: *IDBObjectStore, txn: *IDBTransaction, index_id: ?i64, source: Source, bounds: Engine.Bounds, direction: Direction, key_only: bool, exec: *Execution) !*IDBRequest {
    try txn.ensureBegun();

    const request = try txn.newRequest();
    const self = try exec._factory.create(IDBCursor{
        ._engine = store._engine,
        ._store = store,
        ._txn = txn,
        ._request = request,
        ._bounds = bounds,
        ._direction = direction,
        ._key_only = key_only,
        ._index_id = index_id,
        ._js = undefined,
        ._source = source,
    });
    request._cursor = self;

    const local = exec.js.local.?;
    const public: js.Value = if (key_only)
        try local.zigValueToJs(self, .{})
    else
        try local.zigValueToJs(try IDBCursorWithValue.init(self, exec), .{});

    // Pre-converted and cached because it's the request value on every iteration,
    // avoiding the bridge's pointer -> js.Value lookup each time.
    self._js = try public.persist();

    try self.iterate(.first, 0, exec);
    return request;
}

// Called by IDBRequest.deliver right before a cursor's success handler runs.
pub fn beforeDeliver(self: *IDBCursor) void {
    self._got_value = self._key != null;
}

pub fn @"continue"(self: *IDBCursor, key_arg: ?js.Value, exec: *Execution) !void {
    try self.prepareIterate();

    if (key_arg) |k| {
        const encoded = try Key.encodeValue(exec.arena, k);
        // The target must move past the current key in the iteration direction.
        const order = std.mem.order(u8, encoded, self._key.?);
        if (if (self._direction.reverse()) order != .lt else order != .gt) {
            return error.DataError;
        }
        try self.iterate(.{ .to = encoded }, 0, exec);
    } else {
        try self.iterate(.next, 0, exec);
    }
    try self._txn.enqueue(self._request);
}

pub fn continuePrimaryKey(self: *IDBCursor, key_arg: js.Value, primary_key_arg: js.Value, exec: *Execution) !void {
    // Only meaningful on an index cursor with a directed (non-unique) direction.
    if (self._index_id == null or self._direction == .nextunique or self._direction == .prevunique) {
        return error.InvalidAccessError;
    }
    try self.prepareIterate();

    const reverse = self._direction.reverse();
    const key = try Key.encodeValue(exec.arena, key_arg);
    const primary_key = try Key.encodeValue(exec.arena, primary_key_arg);

    // The (key, primaryKey) pair must move past the current position.
    const ok = switch (std.mem.order(u8, key, self._key.?)) {
        .gt => !reverse,
        .lt => reverse,
        .eq => blk: {
            const pk_order = std.mem.order(u8, primary_key, self._primary_key.?);
            break :blk if (reverse) pk_order == .lt else pk_order == .gt;
        },
    };
    if (!ok) return error.DataError;

    try self.iterate(.{ .to_primary = .{ .key = key, .primary_key = primary_key } }, 0, exec);
    try self._txn.enqueue(self._request);
}

pub fn advance(self: *IDBCursor, count: u32, exec: *Execution) !void {
    if (count == 0) {
        return error.TypeError;
    }

    try self.prepareIterate();
    // `count` records forward = skip count-1 past the immediate next.
    try self.iterate(.next, count - 1, exec);
    try self._txn.enqueue(self._request);
}

pub fn update(self: *IDBCursor, value: js.Value, exec: *Execution) !*IDBRequest {
    if (self._txn._mode == .readonly) {
        return error.ReadOnlyError;
    }

    if (self._txn._settled == true) {
        return error.TransactionInactiveError;
    }

    if (self._got_value == false) {
        return error.InvalidStateError;
    }

    // The record sits at the primary (store) key, even for an index cursor.
    const key = self._primary_key orelse return error.InvalidStateError;

    // For an in-line store, the value's own key must match the record's key.
    if (self._store._key_path) |kp| {
        const extracted = Key.evaluatePath(value, kp) orelse return error.DataError;
        const encoded = try Key.encodeValue(exec.call_arena, extracted);
        if (!std.mem.eql(u8, encoded, key)) {
            return error.DataError;
        }
    }

    const serialized = try value.serialize();
    defer serialized.deinit();

    const request = try self._txn.newRequest();
    self._store.writeAt(key, value, serialized.bytes(), exec) catch |err| {
        log.warn(.storage, "idb cursor update", .{ .err = err });
        request.setError(err);
        return request;
    };
    try request.setValue(try Key.decodeToJs(exec.call_arena, exec.js.local.?, key));
    return request;
}

pub fn delete(self: *IDBCursor) !*IDBRequest {
    if (self._txn._mode == .readonly) {
        return error.ReadOnlyError;
    }

    if (self._txn._settled == true) {
        return error.TransactionInactiveError;
    }

    if (self._got_value == false) {
        return error.InvalidStateError;
    }

    const key = self._primary_key orelse return error.InvalidStateError;

    const request = try self._txn.newRequest();
    self._store.deleteAt(key) catch |err| {
        log.warn(.storage, "idb cursor delete", .{ .err = err });
        request.setError(err);
    };
    return request;
}

pub fn getKey(self: *const IDBCursor, exec: *Execution) !?js.Value {
    const encoded = self._key orelse return null;
    return try Key.decodeToJs(exec.call_arena, exec.js.local.?, encoded);
}

pub fn getPrimaryKey(self: *const IDBCursor, exec: *Execution) !?js.Value {
    const encoded = self._primary_key orelse return null;
    return try Key.decodeToJs(exec.call_arena, exec.js.local.?, encoded);
}

pub fn getDirection(self: *const IDBCursor) Direction {
    return self._direction;
}

// The bridge converts the active union variant (the IDBObjectStore/IDBIndex).
pub fn getSource(self: *const IDBCursor) Source {
    return self._source;
}

// Seek the next record and stage it as the request result. The keys/value live on
// the page arena (they must survive across event-loop turns within the txn).
fn iterate(self: *IDBCursor, seek: Seek, offset: u32, exec: *Execution) !void {
    const reverse = self._direction.reverse();
    const arena = exec.arena;
    const store_id = self._store._store_id;

    if (self._index_id) |index_id| {
        const from_key, const from_pk, const pk_inclusive = switch (seek) {
            .first => .{ startSentinel(reverse), startSentinel(reverse), false },
            .next => .{ self._key.?, self._primary_key.?, false },
            .to => |t| .{ t, startSentinel(reverse), false },
            .to_primary => |tp| .{ tp.key, tp.primary_key, true },
        };
        const rec = try self._engine.indexCursorSeek(arena, store_id, index_id, self._bounds, reverse, from_key, from_pk, pk_inclusive, !self._key_only, offset);
        if (rec) |r| self.position(r.key, r.primary_key, r.value) else self.exhaust();
    } else {
        const from_op, const from_key = switch (seek) {
            .first => .{ if (reverse) "<= " else ">= ", startSentinel(reverse) },
            .next => .{ if (reverse) "< " else "> ", self._key.? },
            .to => |t| .{ if (reverse) "<= " else ">= ", t },
            .to_primary => return error.InvalidAccessError,
        };
        const rec = try self._engine.cursorSeek(arena, store_id, self._bounds, reverse, from_op, from_key, offset, !self._key_only);
        // For an object store the key is the primary key.
        if (rec) |r| self.position(r.key, r.key, r.value) else self.exhaust();
    }
}

fn position(self: *IDBCursor, key: []const u8, primary_key: []const u8, value: ?[]const u8) void {
    self._key = key;
    self._primary_key = primary_key;
    self._value = value;
    self._request.setValueGlobal(self._js);
}

fn exhaust(self: *IDBCursor) void {
    self._key = null;
    self._primary_key = null;
    self._value = null;
    self._request.setNull();
}

// validate the state before we can advance/continue
fn prepareIterate(self: *IDBCursor) !void {
    if (self._txn._settled == true) {
        return error.TransactionInactiveError;
    }

    if (self._got_value == false) {
        return error.InvalidStateError;
    }

    self._got_value = false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBCursor);

    pub const Meta = struct {
        pub const name = "IDBCursor";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const key = bridge.accessor(IDBCursor.getKey, null, .{ .null_as_undefined = true });
    pub const primaryKey = bridge.accessor(IDBCursor.getPrimaryKey, null, .{ .null_as_undefined = true });
    pub const direction = bridge.accessor(IDBCursor.getDirection, null, .{});
    pub const source = bridge.accessor(IDBCursor.getSource, null, .{});
    pub const @"continue" = bridge.function(IDBCursor.@"continue", .{ });
    pub const continuePrimaryKey = bridge.function(IDBCursor.continuePrimaryKey, .{ });
    pub const advance = bridge.function(IDBCursor.advance, .{ });
    pub const update = bridge.function(IDBCursor.update, .{ });
    pub const delete = bridge.function(IDBCursor.delete, .{ });
};
