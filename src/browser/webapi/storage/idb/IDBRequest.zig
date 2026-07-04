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

const log = lp.log;
const Execution = js.Execution;
const FunctionSetter = idb.FunctionSetter;

const IDBRequest = @This();

_proto: *EventTarget,
_op: Operation = .none,
_error: ?anyerror = null,
_txn: Txn = .none,
// Same request can show up multiple times in txn._requests, but it should only
// be executed/fired in its last append (to preserve ordering).
_txn_index: usize = 0,
_cursor: ?*IDBCursor = null,
_source: Source = .{ .none = null },
_ready_state: ReadyState = .pending,
_result: Result = .{ .none = js.Undefined{} },
// whether or not we own th result value, if we do, we can free it once we know
// it cannot be used
_result_owned: bool = false,

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
    value: *js.GlobalSlot, // the result of a get/add/put, or a positioned cursor
    database: *IDBDatabase, // the result of an open
};

const Source = union(enum) {
    none: ?js.Undefined,
    store: *IDBObjectStore,
    index: *IDBIndex,
    cursor: *IDBCursor,
};

const Txn = union(enum) {
    // a page-scoped open/deleteDatabase request, outside an upgrade
    none,

    // The transaction this request belongs to — and whose arena it lives on.
    // Set once by IDBTransaction.newRequest, before the request is ever
    // wrapped, and never reassigned: the FC acquire and release must resolve
    // the same target. Wrapper pins forward to it.
    owned: *IDBTransaction,

    // An open request's exposure of the versionchange transaction while the
    // upgrade runs — spec visibility only, not ownership: the request stays
    // page-scoped and pins nothing.
    borrowed: *IDBTransaction,
};

pub fn init(exec: *Execution) !*IDBRequest {
    return exec._factory.eventTarget(IDBRequest{ ._proto = undefined });
}

pub fn asEventTarget(self: *IDBRequest) *EventTarget {
    return self._proto;
}

// The FC machinery calls these when a JS wrapper is created/collected. A
// request created through a transaction lives on that transaction's arena and
// forwards its wrapper pins there; open/delete requests are page-scoped and
// pin nothing.
pub fn acquireRef(self: *IDBRequest) void {
    switch (self._txn) {
        .owned => |txn| txn.acquireRef(),
        .none, .borrowed => {},
    }
}

pub fn releaseRef(self: *IDBRequest, page: *Page) void {
    if (self._op == .none and self._ready_state == .done) {
        // v8 is done with this request and we're done with it. Eagerly release
        // our value
        self.clearOwnedResult();
    }
    switch (self._txn) {
        .owned => |txn| txn.releaseRef(page),
        .none, .borrowed => {},
    }
}

// Release the result handle if this request owns one.
fn clearOwnedResult(self: *IDBRequest) void {
    if (!self._result_owned) {
        return;
    }

    self._result_owned = false;
    switch (self._result) {
        .value => |global| {
            // It's ok to keep this in txn._globals, reset can be called multiple times
            global.reset();
            self._result = .{ .none = js.Undefined{} };
        },
        .none, .database => {},
    }
}

// Not exposed to JS, called internally. Only requests created through a
// transaction (newRequest) carry value results; open/delete requests use
// setDatabaseResult or errors.
pub fn setValue(self: *IDBRequest, value: js.Value) !void {
    const global = try self._txn.owned.persist(value);
    self.clearOwnedResult();
    self._result = .{ .value = global };
    self._result_owned = true;
}

// Not exposed to JS, called internally. The handle is borrowed (a cursor's
// transaction-owned _js), not owned by this request.
pub fn setValueGlobal(self: *IDBRequest, global: *js.GlobalSlot) void {
    self.clearOwnedResult();
    self._result = .{ .value = global };
}

// Not exposed to JS, called internally. Result becomes JS `null` (not undefined).
pub fn setNull(self: *IDBRequest) void {
    self.clearOwnedResult();
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
        return self.fireError(exec);
    }
    if (self._cursor) |cursor| {
        // A cursor request re-fires on every iteration; let the cursor mark itself
        // readable (got value) right before the success handler runs.
        cursor.beforeDeliver();
    }
    return self.fireSuccess(exec);
}

pub fn fireUpgradeNeeded(self: *IDBRequest, exec: *Execution, old_version: u64, new_version: u64) !void {
    self._ready_state = .done;
    const event = try IDBVersionChangeEvent.initTrusted(.wrap("upgradeneeded"), old_version, new_version, exec);
    try exec.dispatch(self.asEventTarget(), event.asEvent(), self._on_upgrade_needed, .{ .context = "IDBRequest.upgradeneeded" });
}

pub fn fireSuccess(self: *IDBRequest, exec: *Execution) !void {
    self._ready_state = .done;

    const event = try Event.initTrusted(comptime .wrap("success"), null, exec.page);
    event.acquireRef();
    defer _ = event.releaseRef(exec.page);

    try exec.dispatch(self.asEventTarget(), event, self._on_success, .{ .context = "IDBRequest.success" });

    if (event._listeners_did_throw) blk: {
        // if the event threw, we must abort
        const txn = switch (self._txn) {
            .owned => |t| t,
            .none, .borrowed => break :blk,
        };

        if (!txn._settled and !txn._committing) {
            txn.abortWith(exec, error.AbortError) catch |err| {
                log.warn(.storage, "idb success-event abort", .{ .err = err });
            };
        }
    }
}

fn fireError(self: *IDBRequest, exec: *Execution) !void {
    // Requests created inside a transaction own an abortable transaction; open/
    // delete requests (and the borrowed upgrade-transaction view) do not.
    const txn: ?*IDBTransaction = switch (self._txn) {
        .owned => |t| t,
        .none, .borrowed => null,
    };

    const event = try Event.initTrusted(comptime .wrap("error"), .{ .bubbles = true, .cancelable = true }, exec.page);
    event.acquireRef();
    defer _ = event.releaseRef(exec.page);

    const et = self.asEventTarget();
    event._target = et;
    event._dispatch_target = et;

    try exec.dispatch(et, event, self._on_error, .{ .context = "IDBRequest.error", .inject_target = false });
    if (txn) |tx| {
        if (!event._stop_propagation) {
            try exec.dispatch(tx.asEventTarget(), event, tx._on_error, .{ .context = "IDBTransaction.error", .inject_target = false });
        }
        if (!event._stop_propagation) {
            const db = tx._db;
            try exec.dispatch(db.asEventTarget(), event, db._on_error, .{ .context = "IDBDatabase.error", .inject_target = false });
        }

        // Don't re-abort a transaction that's already finishing — the AbortError
        // events an abort itself delivers come back through here.
        if (!tx._settled and !tx._committing) {
            const reason: ?anyerror = if (event._listeners_did_throw)
                error.AbortError
            else if (!event._prevent_default)
                self._error
            else
                null;
            if (reason != null) {
                // catch (rather than propagate): the abort's own event dispatch
                // can re-enter here, so keeping the error set out of deliver's
                // recursion is both simpler and avoids an unresolvable inferred set.
                tx.abortWith(exec, reason) catch |err| {
                    log.warn(.storage, "idb error-event abort", .{ .err = err });
                };
            }
        }
    }
}

pub fn getReadyState(self: *const IDBRequest) ReadyState {
    return self._ready_state;
}

// What the `result` accessor hands the bridge: the stored handle resolved to a
// local value.
const JsResult = union(enum) {
    value: js.Value,
    none: ?js.Undefined,
    database: *IDBDatabase,
};

pub fn getResult(self: *const IDBRequest, exec: *Execution) JsResult {
    return switch (self._result) {
        .none => |n| .{ .none = n },
        .value => |global| .{ .value = global.local(exec.js.local.?) },
        .database => |db| .{ .database = db },
    };
}

// The bridge converts the active union variant (the store/index/cursor, or JS
// null for an open/delete request).
pub fn getSource(self: *const IDBRequest) Source {
    return self._source;
}

pub fn getTransaction(self: *const IDBRequest) ?*IDBTransaction {
    return switch (self._txn) {
        .none => null,
        .owned, .borrowed => |txn| txn,
    };
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
    const StoreWrite = struct { store: *IDBObjectStore, kind: IDBObjectStore.WriteKind, value: *js.GlobalSlot, key: IDBObjectStore.PreparedKey };
    const IndexQuery = struct { index: *IDBIndex, bounds: Engine.Bounds };
    const IndexGetAll = struct { index: *IDBIndex, args: IDBKeyRange.GetAllArgs, mode: IDBObjectStore.GetAllMode };
    const CursorIterate = struct { cursor: *IDBCursor, seek: IDBCursor.Seek, offset: u32 };
    const CursorUpdate = struct { cursor: *IDBCursor, key: []const u8, value: []const u8 };
    const CursorDelete = struct { cursor: *IDBCursor, key: []const u8 };

    fn source(op: Operation) Source {
        return switch (op) {
            .none => .{ .none = null },
            .store_get, .store_get_key, .store_count, .store_delete => |o| .{ .store = o.store },
            .store_get_all => |o| .{ .store = o.store },
            .store_clear => |store| .{ .store = store },
            .store_write => |o| .{ .store = o.store },
            .index_get, .index_get_key, .index_count => |o| .{ .index = o.index },
            .index_get_all => |o| .{ .index = o.index },
            .cursor_iterate => |o| switch (o.cursor._source) {
                .store => |s| .{ .store = s },
                .index => |x| .{ .index = x },
            },
            .cursor_update => |o| .{ .cursor = o.cursor },
            .cursor_delete => |o| .{ .cursor = o.cursor },
        };
    }
};

// Commit this request's operation: record it and queue the request on its
// transaction's drain.
pub fn submit(self: *IDBRequest, op: Operation, exec: *Execution) !*IDBRequest {
    self._op = op;
    self._source = op.source();
    const txn = self._txn.owned;
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
    switch (self._txn) {
        .owned => |txn| try txn.ensureBegun(),
        .none, .borrowed => {},
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
    pub const source = bridge.accessor(IDBRequest.getSource, null, .{});
    pub const transaction = bridge.accessor(IDBRequest.getTransaction, null, .{ .null_as_undefined = true });
    pub const @"error" = bridge.accessor(IDBRequest.getError, null, .{ .null_as_undefined = true });
    pub const onsuccess = bridge.accessor(IDBRequest.getOnSuccess, IDBRequest.setOnSuccess, .{});
    pub const onerror = bridge.accessor(IDBRequest.getOnError, IDBRequest.setOnError, .{});
    pub const onupgradeneeded = bridge.accessor(IDBRequest.getOnUpgradeNeeded, IDBRequest.setOnUpgradeNeeded, .{});
};
