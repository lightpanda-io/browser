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

const Event = @import("../../Event.zig");
const EventTarget = @import("../../EventTarget.zig");
const DOMException = @import("../../DOMException.zig");

const idb = @import("idb.zig");
const Engine = @import("Engine.zig");
const IDBIndex = @import("IDBIndex.zig");
const IDBCursor = @import("IDBCursor.zig");
const IDBDatabase = @import("IDBDatabase.zig");
const IDBKeyRange = @import("IDBKeyRange.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const IDBVersionChangeEvent = @import("IDBVersionChangeEvent.zig");

const Execution = js.Execution;
const FunctionSetter = idb.FunctionSetter;

const IDBRequest = @This();

_proto: *EventTarget,
_op: Operation = .none,
_error: ?anyerror = null,
_txn: ?*IDBTransaction = null,
// Same request can show up multiple times in txn._requests, but it should only
// be executed/fired in its last append (to preserve ordering).
_txn_index: usize = 0,
_cursor: ?*IDBCursor = null,
_ready_state: ReadyState = .pending,
_result: Result = .{ .none = js.Undefined{} },

_on_success: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_upgrade_needed: ?js.Function.Global = null,

const ReadyState = enum {
    pending,
    done,

    pub fn toString(self: ReadyState) []const u8 {
        return @tagName(self);
    }
};

const Result = union(enum) {
    none: ?js.Undefined, // null or undefined (different APIs return different values)
    value: js.Value.Global, // the result of a get/add/put, or a positioned cursor
    database: *IDBDatabase, // the result of an open
};

pub fn init(exec: *Execution) !*IDBRequest {
    return exec._factory.eventTarget(IDBRequest{ ._proto = undefined });
}

pub fn asEventTarget(self: *IDBRequest) *EventTarget {
    return self._proto;
}

// Not exposed to JS, called internally
pub fn setValue(self: *IDBRequest, value: js.Value) !void {
    return self.setValueGlobal(try value.persist());
}

// Not exposed to JS, called internally
pub fn setValueGlobal(self: *IDBRequest, global: js.Value.Global) void {
    self._result = .{ .value = global };
}

// Not exposed to JS, called internally. Result becomes JS `null` (not undefined).
pub fn setNull(self: *IDBRequest) void {
    self._result = .{ .none = null };
}

// Not exposed to JS, called internally
pub fn setDatabaseResult(self: *IDBRequest, database: *IDBDatabase) void {
    self._result = .{ .database = database };
}

// Not exposed to JS, called internally
pub fn setError(self: *IDBRequest, err: anyerror) void {
    self._error = err;
}

pub fn failed(self: *const IDBRequest) bool {
    return self._error != null;
}

pub fn deliver(self: *IDBRequest, exec: *Execution) !void {
    self._ready_state = .done;
    if (self._error != null) {
        return self.fire(exec, comptime .wrap("error"), self._on_error);
    }
    if (self._cursor) |cursor| {
        // A cursor request re-fires on every iteration; let the cursor mark itself
        // readable (got value) right before the success handler runs.
        cursor.beforeDeliver();
    }
    return self.fire(exec, comptime .wrap("success"), self._on_success);
}

pub fn fireUpgradeNeeded(self: *IDBRequest, exec: *Execution, old_version: u64, new_version: u64) !void {
    self._ready_state = .done;
    const event = try IDBVersionChangeEvent.initTrusted(.wrap("upgradeneeded"), old_version, new_version, exec);
    try exec.dispatch(self.asEventTarget(), event.asEvent(), self._on_upgrade_needed, .{ .context = "IDBRequest.upgradeneeded" });
}

pub fn fireSuccess(self: *IDBRequest, exec: *Execution) !void {
    self._ready_state = .done;
    return self.fire(exec, comptime .wrap("success"), self._on_success);
}

fn fire(self: *IDBRequest, exec: *Execution, typ: lp.String, handler: ?js.Function.Global) !void {
    const event = try Event.initTrusted(typ, null, exec.page);
    try exec.dispatch(self.asEventTarget(), event, handler, .{ .context = "IDBRequest" });
}

pub fn getReadyState(self: *const IDBRequest) ReadyState {
    return self._ready_state;
}

pub fn getResult(self: *const IDBRequest) Result {
    return self._result;
}

pub fn getTransaction(self: *const IDBRequest) ?*IDBTransaction {
    return self._txn;
}

// Return this as a DOMException directly. If we return an error, the bridge
// *will* convert it to a DOMException, but it'll throw it, not return it.
pub fn getError(self: *const IDBRequest) ?DOMException {
    const err = self._error orelse return null;
    const mapped: anyerror = switch (err) {
        // sqlite's generic constraint failure is IDB's ConstraintError.
        error.Constraint => error.ConstraintError,
        else => err,
    };
    return DOMException.fromError(mapped) orelse DOMException.init(null, "UnknownError");
}

pub fn getOnSuccess(self: *const IDBRequest) ?js.Function.Global {
    return self._on_success;
}

pub fn setOnSuccess(self: *IDBRequest, setter: ?FunctionSetter) void {
    self._on_success = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const IDBRequest) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *IDBRequest, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnUpgradeNeeded(self: *const IDBRequest) ?js.Function.Global {
    return self._on_upgrade_needed;
}

pub fn setOnUpgradeNeeded(self: *IDBRequest, setter: ?FunctionSetter) void {
    self._on_upgrade_needed = getFunctionFromSetter(setter);
}

fn getFunctionFromSetter(setter: ?FunctionSetter) ?js.Function.Global {
    const s = setter orelse return null;
    return switch (s) {
        .func => |f| f,
        .anything => null,
    };
}

// A database operation, captured when a request method is called and run later.
pub const Operation = union(enum) {
    none,
    store_get: StoreQuery,
    store_get_key: StoreQuery,
    store_get_all: StoreGetAll,
    store_count: StoreQuery,
    store_delete: StoreQuery,
    store_clear: *IDBObjectStore,
    store_write: StoreWrite,
    index_get: IndexQuery,
    index_get_key: IndexQuery,
    index_get_all: IndexGetAll,
    index_count: IndexQuery,
    cursor_iterate: CursorIterate,
    cursor_update: CursorUpdate,
    cursor_delete: CursorDelete,

    const StoreQuery = struct { store: *IDBObjectStore, bounds: Engine.Bounds };
    const StoreGetAll = struct { store: *IDBObjectStore, args: IDBKeyRange.GetAllArgs, mode: IDBObjectStore.GetAllMode };
    const StoreWrite = struct { store: *IDBObjectStore, kind: IDBObjectStore.WriteKind, value: js.Value.Global, key: IDBObjectStore.PreparedKey };
    const IndexQuery = struct { index: *IDBIndex, bounds: Engine.Bounds };
    const IndexGetAll = struct { index: *IDBIndex, args: IDBKeyRange.GetAllArgs, mode: IDBObjectStore.GetAllMode };
    const CursorIterate = struct { cursor: *IDBCursor, seek: IDBCursor.Seek, offset: u32 };
    const CursorUpdate = struct { cursor: *IDBCursor, key: []const u8, value: js.Value.Global };
    const CursorDelete = struct { cursor: *IDBCursor, key: []const u8 };
};

// Commit this request's operation: record it and queue the request on its
// transaction's drain.
pub fn submit(self: *IDBRequest, op: Operation, exec: *Execution) !*IDBRequest {
    self._op = op;
    const txn = self._txn.?;
    try txn.enqueue(self);

    if (txn.getMode() == .versionchange) {
        // for "upgradeneeded" we run them immediately (and still queue them, but
        // their .op == .noop at that point). This is necessary to keep this
        // operation consistent / ordered with other "upgradeneeded" changes that
        // happen synchronously (e.g. createIndex). And we queue it so that,
        // while the re-execute will be noop, the events will still fire.
        try self.execute(exec);
    }
    return self;
}

pub fn execute(self: *IDBRequest, exec: *Execution) !void {
    const op = self._op;
    if (op == .none) {
        return;
    }

    self._op = .none;
    if (self._txn) |txn| {
        try txn.ensureBegun();
    }
    switch (op) {
        .none => unreachable,
        .store_get => |o| try o.store.runGet(self, o.bounds, exec),
        .store_get_key => |o| try o.store.runGetKey(self, o.bounds, exec),
        .store_get_all => |o| try o.store.runGetAll(self, o.args, o.mode, exec),
        .store_count => |o| try o.store.runCount(self, o.bounds, exec),
        .store_delete => |o| try o.store.runDelete(self, o.bounds, exec),
        .store_clear => |store| try store.runClear(self, exec),
        .store_write => |o| try o.store.runWrite(self, o.kind, o.value, o.key, exec),
        .index_get => |o| try o.index.runGet(self, o.bounds, exec),
        .index_get_key => |o| try o.index.runGetKey(self, o.bounds, exec),
        .index_get_all => |o| try o.index.runGetAll(self, o.args, o.mode, exec),
        .index_count => |o| try o.index.runCount(self, o.bounds, exec),
        .cursor_iterate => |o| try o.cursor.runIterate(o.seek, o.offset, exec),
        .cursor_update => |o| try o.cursor.runUpdate(self, o.key, o.value, exec),
        .cursor_delete => |o| try o.cursor.runDelete(self, o.key),
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBRequest);

    pub const Meta = struct {
        pub const name = "IDBRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const readyState = bridge.accessor(IDBRequest.getReadyState, null, .{});
    pub const result = bridge.accessor(IDBRequest.getResult, null, .{});
    pub const transaction = bridge.accessor(IDBRequest.getTransaction, null, .{ .null_as_undefined = true });
    pub const @"error" = bridge.accessor(IDBRequest.getError, null, .{ .null_as_undefined = true });
    pub const onsuccess = bridge.accessor(IDBRequest.getOnSuccess, IDBRequest.setOnSuccess, .{});
    pub const onerror = bridge.accessor(IDBRequest.getOnError, IDBRequest.setOnError, .{});
    pub const onupgradeneeded = bridge.accessor(IDBRequest.getOnUpgradeNeeded, IDBRequest.setOnUpgradeNeeded, .{});
};
