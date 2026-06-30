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

// the JS value of this Cursor, pre-converted and cached as an optimization
// since this cursor will be the request value on every iteration.
_js: js.Value.Global,

// Encoded current key; null before iteration and at the end
_key: ?[]const u8 = null,
// Current record's serialized value bytes (null when key-only or exhausted).
_value: ?[]const u8 = null,
// The spec's "got value flag": gated true only while a success handler can read
// the cursor, set just before each delivery and cleared by continue/advance.
_got_value: bool = false,

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

// Create a cursor over `store` and run the first seek. Returns the request that
// delivers the cursor (or null) via repeated `success` events.
pub fn open(store: *IDBObjectStore, bounds: Engine.Bounds, direction: Direction, key_only: bool, exec: *Execution) !*IDBRequest {
    const txn = store._txn orelse return error.TransactionInactiveError;
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
        ._js = undefined,
    });
    request._cursor = self;

    const local = exec.js.local.?;

    const public: js.Value = if (key_only)
        try local.zigValueToJs(self, .{})
    else
        try local.zigValueToJs(try IDBCursorWithValue.init(self, exec), .{});

    // An optimization. Potentially looked up _a lot_, so calculating upfront
    // storing it, and setting it in the IDBRequest (which is already js.Value.Global
    // aware), avoids the lookup we'd normally have to do in the bridge.
    self._js = try public.persist();

    const reverse = direction.reverse();
    try self.iterate(if (reverse) "<= " else ">= ", if (reverse) Engine.Bounds.max_sentinel else Engine.Bounds.min_sentinel, 0, exec);
    return request;
}

// Called by IDBRequest.deliver right before a cursor's success handler runs.
pub fn beforeDeliver(self: *IDBCursor) void {
    self._got_value = self._key != null;
}

pub fn @"continue"(self: *IDBCursor, key_arg: ?js.Value, exec: *Execution) !void {
    try self.prepareIterate();
    const reverse = self._direction.reverse();

    if (key_arg) |k| {
        const encoded = try Key.encodeValue(exec.arena, k);
        // The target must move past the current key in the iteration direction.
        const order = std.mem.order(u8, encoded, self._key.?);
        if (if (reverse) order != .lt else order != .gt) {
            return error.DataError;
        }
        try self.iterate(if (reverse) "<= " else ">= ", encoded, 0, exec);
    } else {
        try self.iterate(if (reverse) "< " else "> ", self._key.?, 0, exec);
    }
    try self._txn.enqueue(self._request);
}

pub fn advance(self: *IDBCursor, count: u32, exec: *Execution) !void {
    if (count == 0) {
        return error.TypeError;
    }

    try self.prepareIterate();
    const reverse = self._direction.reverse();
    // `count` records forward = skip count-1 past the immediate next.
    try self.iterate(if (reverse) "< " else "> ", self._key.?, count - 1, exec);
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

    const key = self._key orelse return error.InvalidStateError;

    // For an in-line store, the value's own key must match the cursor's key.
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
    self._engine.put(self._store._store_id, key, serialized.bytes()) catch |err| {
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

    const key = self._key orelse return error.InvalidStateError;

    const request = try self._txn.newRequest();
    self._engine.deleteRange(self._store._store_id, Engine.Bounds.point(key)) catch |err| {
        log.warn(.storage, "idb cursor delete", .{ .err = err });
        request.setError(err);
    };
    return request;
}

pub fn getKey(self: *const IDBCursor, exec: *Execution) !?js.Value {
    const encoded = self._key orelse return null;
    return try Key.decodeToJs(exec.call_arena, exec.js.local.?, encoded);
}

// For an object store the primary key is the key.
pub fn getPrimaryKey(self: *const IDBCursor, exec: *Execution) !?js.Value {
    return self.getKey(exec);
}

pub fn getDirection(self: *const IDBCursor) Direction {
    return self._direction;
}

pub fn getSource(self: *const IDBCursor) *IDBObjectStore {
    return self._store;
}

// Seek the next record and stage it as the request result. The key/value live on
// the page arena (they must survive across event-loop turns within the txn).
fn iterate(self: *IDBCursor, from_op: []const u8, from_key: []const u8, offset: u32, exec: *Execution) !void {
    const reverse = self._direction.reverse();
    const rec = try self._engine.cursorSeek(exec.arena, self._store._store_id, self._bounds, reverse, from_op, from_key, offset, !self._key_only);
    if (rec) |r| {
        self._key = r.key;
        self._value = r.value; // already null for a key-only cursor
        self._request.setValueGlobal(self._js);
    } else {
        self._key = null;
        self._value = null;
        self._request.setNull();
    }
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
    pub const @"continue" = bridge.function(IDBCursor.@"continue", .{ .dom_exception = true });
    pub const advance = bridge.function(IDBCursor.advance, .{ .dom_exception = true });
    pub const update = bridge.function(IDBCursor.update, .{ .dom_exception = true });
    pub const delete = bridge.function(IDBCursor.delete, .{ .dom_exception = true });
};
