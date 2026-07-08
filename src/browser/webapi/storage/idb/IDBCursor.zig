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
_js: *js.Value.BareGlobal,

// Encoded current key; null before iteration and at the end. For an index cursor
// this is the index key; for an object store it equals the primary key.
_key: ?[]const u8 = null,

// Encoded primary (store) key. Equals _key for an object-store cursor.
_primary_key: ?[]const u8 = null,
// Current record's serialized value bytes (null when key-only or exhausted).
_value: ?[]const u8 = null,
// The deserialized JS value, cached so repeated `.value` reads return the same
// object (and observe mutations to it). Reset whenever the cursor repositions.
_value_js: ?*js.Value.BareGlobal = null,

// Backing storage for _key/_primary_key/_value, reused across positions so a
// long scan holds one record's worth of memory, not the whole traversal.
// Anything that must survive a reposition (update/delete/continue snapshots)
// is duped onto the transaction's arena instead.
_key_buf: std.ArrayList(u8) = .empty,
_pk_buf: std.ArrayList(u8) = .empty,
_val_buf: std.ArrayList(u8) = .empty,

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
pub const Seek = union(enum) {
    first, // start of the range, in the iteration direction
    next, // strictly past the current position
    to: []const u8, // continue(key): first record at/after an index/store key
    to_primary: struct { key: []const u8, primary_key: []const u8 }, // continuePrimaryKey
};

fn startSentinel(reverse: bool) []const u8 {
    return if (reverse) Engine.Bounds.max_sentinel else Engine.Bounds.min_sentinel;
}

// Cursor over an object store.
pub fn init(store: *IDBObjectStore, bounds: Engine.Bounds, direction: Direction, key_only: bool, exec: *Execution) !*IDBRequest {
    return _init(store, store._txn, null, .{ .store = store }, bounds, direction, key_only, exec);
}

// Cursor over an index (key = index key, primaryKey = store key).
pub fn initIndex(index: *IDBIndex, bounds: Engine.Bounds, direction: Direction, key_only: bool, exec: *Execution) !*IDBRequest {
    const store = index._store;
    return _init(store, store._txn, index._index_id, .{ .index = index }, bounds, direction, key_only, exec);
}

fn _init(store: *IDBObjectStore, txn: *IDBTransaction, index_id: ?i64, source: Source, bounds: Engine.Bounds, direction: Direction, key_only: bool, exec: *Execution) !*IDBRequest {
    try txn.assertActive();

    const request = try txn.newRequest();
    const self = try txn._arena.create(IDBCursor);
    self.* = .{
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
    };
    request._cursor = self;

    const local = exec.js.local.?;
    const public: js.Value = if (key_only)
        try local.zigValueToJs(self, .{})
    else
        try local.zigValueToJs(try IDBCursorWithValue.init(self), .{});

    // Pre-converted and cached because it's the request value on every iteration,
    // avoiding the bridge's pointer -> js.Value lookup each time.
    self._js = try txn.persist(public);

    // The first seek runs in the drain (or immediately, for a versionchange txn),
    // not here — so the connection is only touched while the txn owns it.
    return request.submit(.{ .cursor_iterate = .{ .cursor = self, .seek = .first, .offset = 0 } }, exec);
}

pub fn acquireRef(self: *IDBCursor) void {
    self._txn.acquireRef();
}

pub fn releaseRef(self: *IDBCursor, page: *Page) void {
    self._txn.releaseRef(page);
}

// Run the deferred seek, staging the positioned cursor (or null) on the request.
pub fn runIterate(self: *IDBCursor, seek: Seek, offset: u32, exec: *Execution) !void {
    self.iterate(seek, offset, exec) catch |err| {
        log.warn(.storage, "idb cursor iterate", .{ .err = err, .sqlite = self._engine.lastError() });
        self._request.setError(err);
    };
}

// Called by IDBRequest.deliver right before a cursor's success handler runs.
pub fn beforeDeliver(self: *IDBCursor) void {
    self._got_value = self._key != null;
}

pub fn @"continue"(self: *IDBCursor, key_arg: ?js.Value, exec: *Execution) !void {
    try self.assertIterable();

    if (key_arg) |k| {
        // Key conversion (DataError) must run before the got-value flag is
        // cleared, so a failing continue() leaves the cursor re-iterable.
        const encoded = try Key.encodeValue(self._txn._arena, k);
        // The target must move past the current key in the iteration direction.
        const order = std.mem.order(u8, encoded, self._key.?);
        if (if (self._direction.reverse()) order != .lt else order != .gt) {
            return error.DataError;
        }
        self._got_value = false;
        try self.reiterate(.{ .to = encoded }, 0, exec);
    } else {
        self._got_value = false;
        try self.reiterate(.next, 0, exec);
    }
}

pub fn continuePrimaryKey(self: *IDBCursor, key_arg: js.Value, primary_key_arg: js.Value, exec: *Execution) !void {
    // Only meaningful on an index cursor with a directed (non-unique) direction.
    if (self._index_id == null or self._direction == .nextunique or self._direction == .prevunique) {
        return error.InvalidAccessError;
    }
    try self.assertIterable();

    const reverse = self._direction.reverse();
    // Key conversion (DataError) precedes clearing the got-value flag; see continue().
    const key = try Key.encodeValue(self._txn._arena, key_arg);
    const primary_key = try Key.encodeValue(self._txn._arena, primary_key_arg);

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

    self._got_value = false;
    try self.reiterate(.{ .to_primary = .{ .key = key, .primary_key = primary_key } }, 0, exec);
}

pub fn advance(self: *IDBCursor, count: u32, exec: *Execution) !void {
    if (count == 0) {
        return error.TypeError;
    }

    try self.assertIterable();
    self._got_value = false;
    // `count` records forward = skip count-1 past the immediate next.
    try self.reiterate(.next, count - 1, exec);
}

pub fn update(self: *IDBCursor, value: js.Value, exec: *Execution) !*IDBRequest {
    try self.assertCanUpdate();

    // The record sits at the primary (store) key, even for an index cursor.
    const current_key = self._primary_key orelse return error.InvalidStateError;

    // Structured-clone the value now, synchronously: an unserializable value must
    // throw DataCloneError from update() itself, not fail later in the drain. The
    // stored clone also decouples the record from any later mutation of the arg.
    const serialized = value.serialize() catch return error.TryCatchRethrow;
    defer serialized.deinit();

    // For an in-line store, the value's own key must match the record's key.
    if (self._store._key_path) |kp| {
        const extracted = (try Key.extractKeyPath(exec.js.local.?, value, kp)) orelse return error.DataError;
        const encoded = try Key.encodeValue(exec.call_arena, extracted);
        if (!std.mem.eql(u8, encoded, current_key)) {
            return error.DataError;
        }
    }

    // Snapshot the record key and the serialized clone onto the transaction arena:
    // the write runs in the drain, by which point a `continue` could have moved
    // the cursor's live position (and reused its key buffer).
    const key = try self._txn._arena.dupe(u8, current_key);
    const bytes = try self._txn._arena.dupe(u8, serialized.bytes());
    const request = try self._txn.newRequest();
    return request.submit(.{ .cursor_update = .{ .cursor = self, .key = key, .value = bytes } }, exec);
}

pub fn runUpdate(self: *IDBCursor, request: *IDBRequest, key: []const u8, bytes: []const u8, exec: *Execution) !void {
    const local = exec.js.local.?;
    const value = js.Value.deserialize(local, bytes) catch |err| {
        request.setError(err);
        return;
    };

    self._store.writeAt(key, value, bytes, exec) catch |err| {
        log.warn(.storage, "idb cursor update", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
        return;
    };
    try request.setValue(try Key.decodeToJs(exec.call_arena, local, key));
}

pub fn delete(self: *IDBCursor, exec: *Execution) !*IDBRequest {
    try self.assertCanUpdate();

    // Snapshot the record key (see update): the delete runs later, in the drain.
    const current_key = self._primary_key orelse return error.InvalidStateError;
    const key = try self._txn._arena.dupe(u8, current_key);
    const request = try self._txn.newRequest();
    return request.submit(.{ .cursor_delete = .{ .cursor = self, .key = key } }, exec);
}

pub fn runDelete(self: *IDBCursor, request: *IDBRequest, key: []const u8) !void {
    self._store.deleteAt(key) catch |err| {
        log.warn(.storage, "idb cursor delete", .{ .err = err, .sqlite = self._engine.lastError() });
        request.setError(err);
    };
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

// Seek the next record and stage it as the request result. The engine dupes
// the row onto the per-call scratch arena; position() then copies it into the
// cursor's reused buffers (which must survive across event-loop turns).
fn iterate(self: *IDBCursor, seek: Seek, offset: u32, exec: *Execution) !void {
    const reverse = self._direction.reverse();
    const arena = exec.call_arena;
    const store_id = self._store._store_id;

    if (self._index_id) |index_id| {
        const from_key, const from_pk, const pk_inclusive = switch (seek) {
            .first => .{ startSentinel(reverse), startSentinel(reverse), false },
            .next => .{ self._key.?, self._primary_key.?, false },
            .to => |t| .{ t, startSentinel(reverse), false },
            .to_primary => |tp| .{ tp.key, tp.primary_key, true },
        };
        const rec = try self._engine.indexCursorSeek(arena, store_id, index_id, self._bounds, reverse, from_key, from_pk, pk_inclusive, !self._key_only, offset);
        if (rec) |r| try self.position(r.key, r.primary_key, r.value) else self.exhaust();
    } else {
        const from_op, const from_key = switch (seek) {
            .first => .{ if (reverse) "<= " else ">= ", startSentinel(reverse) },
            .next => .{ if (reverse) "< " else "> ", self._key.? },
            .to => |t| .{ if (reverse) "<= " else ">= ", t },
            .to_primary => return error.InvalidAccessError,
        };
        const rec = try self._engine.cursorSeek(arena, store_id, self._bounds, reverse, from_op, from_key, offset, !self._key_only);
        // For an object store the key is the primary key.
        if (rec) |r| try self.position(r.key, r.key, r.value) else self.exhaust();
    }
}

// Re-arm the cursor's existing request with its next seek and requeue it. Called by
// continue/advance from within a success handler; the drain loop picks the requeued
// request up in the same pass (a versionchange cursor runs it now).
fn reiterate(self: *IDBCursor, seek: Seek, offset: u32, exec: *Execution) !void {
    _ = try self._request.submit(.{ .cursor_iterate = .{ .cursor = self, .seek = seek, .offset = offset } }, exec);
}

fn position(self: *IDBCursor, key: []const u8, primary_key: []const u8, value: ?[]const u8) !void {
    const arena = self._txn._arena;
    self.invalidateValue();

    self._key_buf.clearRetainingCapacity();
    try self._key_buf.appendSlice(arena, key);
    self._key = self._key_buf.items;

    self._pk_buf.clearRetainingCapacity();
    try self._pk_buf.appendSlice(arena, primary_key);
    self._primary_key = self._pk_buf.items;

    if (value) |v| {
        self._val_buf.clearRetainingCapacity();
        try self._val_buf.appendSlice(arena, v);
        self._value = self._val_buf.items;
    } else {
        self._value = null;
    }
    self._request.setValueGlobal(self._js);
}

fn exhaust(self: *IDBCursor) void {
    self.invalidateValue();
    self._key = null;
    self._primary_key = null;
    self._value = null;
    self._request.setNull();
}

// Drop any cached `.value` object; the next read re-deserializes at the new
// position. The persisted slot's handle is reset here so it doesn't pin the old
// value until transaction teardown.
fn invalidateValue(self: *IDBCursor) void {
    if (self._value_js) |slot| {
        slot.deinit();
        self._value_js = null;
    }
}

// The deserialized current value, created on first read and cached so repeated
// `.value` accesses return the same JS object (see IDBCursorWithValue.getValue).
pub fn getValueJs(self: *IDBCursor, exec: *Execution) !?js.Value {
    const bytes = self._value orelse return null;
    const local = exec.js.local.?;
    if (self._value_js) |slot| {
        return slot.local(local);
    }
    const value = try js.Value.deserialize(local, bytes);
    self._value_js = try self._txn.persist(value);
    return value;
}

fn assertIterable(self: *IDBCursor) !void {
    if (self._txn._settled == true) {
        return error.TransactionInactiveError;
    }

    if (self._got_value == false) {
        return error.InvalidStateError;
    }
}

fn assertCanUpdate(self: *IDBCursor) !void {
    try self._txn.assertActive();

    if (self._txn._mode == .readonly) {
        return error.ReadOnlyError;
    }
    if (self._store._deleted) {
        return error.InvalidStateError;
    }
    if (self._got_value == false) {
        return error.InvalidStateError;
    }
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
    pub const @"continue" = bridge.function(IDBCursor.@"continue", .{});
    pub const continuePrimaryKey = bridge.function(IDBCursor.continuePrimaryKey, .{});
    pub const advance = bridge.function(IDBCursor.advance, .{});
    pub const update = bridge.function(IDBCursor.update, .{});
    pub const delete = bridge.function(IDBCursor.delete, .{});
};
