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

const idb = @import("idb.zig");
const Engine = @import("Engine.zig");
const IDBDatabase = @import("IDBDatabase.zig");
const IDBRequest = @import("IDBRequest.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");
const DOMStringList = @import("../../collections.zig").DOMStringList;

const log = lp.log;
const Execution = js.Execution;
const FunctionSetter = idb.FunctionSetter;

const IDBTransaction = @This();

_proto: *EventTarget,
_exec: *Execution,
_db: *IDBDatabase,
_engine: *Engine,
_mode: Mode,
// The transaction's scope: the store names it was opened over, sorted and
// deduped. Empty for a versionchange transaction, whose scope is "all stores"
// and is resolved live in getObjectStoreNames.
_scope: []const []const u8 = &.{},
// Advisory only: we always commit through sqlite. Stored to expose the property.
_durability: Durability = .default,
_requests: std.ArrayList(*IDBRequest) = .empty,
_begun: bool = false,
_settled: bool = false,
_aborted: bool = false,
_committing: bool = false,

_on_complete: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_abort: ?js.Function.Global = null,

pub const Mode = enum {
    readonly,
    readwrite,
    versionchange,

    pub fn toString(self: Mode) []const u8 {
        return @tagName(self);
    }
};

pub const Durability = enum {
    default,
    strict,
    relaxed,

    pub const js_enum_from_string = true;

    pub fn toString(self: Durability) []const u8 {
        return @tagName(self);
    }
};

pub fn init(exec: *Execution, db: *IDBDatabase, mode: Mode, durability: Durability, scope: []const []const u8) !*IDBTransaction {
    const self = try exec._factory.eventTarget(IDBTransaction{
        ._proto = undefined,
        ._exec = exec,
        ._db = db,
        ._engine = db._engine,
        ._mode = mode,
        ._scope = scope,
        ._durability = durability,
    });

    // Schedule the drain even for an empty transaction so it still `complete`s.
    try exec.js.scheduler.add(self, drain, 0, .{
        .name = "IDBTransaction.drain",
        .finalizer = finalize,
    });
    return self;
}

// We need a "special" transaction for upgradeneeded
pub fn initVersionChange(exec: *Execution, db: *IDBDatabase) !*IDBTransaction {
    return exec._factory.eventTarget(IDBTransaction{
        ._proto = undefined,
        ._exec = exec,
        ._db = db,
        ._engine = db._engine,
        ._mode = .versionchange,
        ._begun = true,
    });
}

pub fn asEventTarget(self: *IDBTransaction) *EventTarget {
    return self._proto;
}

pub fn aborted(self: *const IDBTransaction) bool {
    return self._aborted;
}

pub fn commit(self: *IDBTransaction, exec: *Execution) !void {
    if (self._settled) {
        return error.InvalidStateError;
    }

    if (self._mode == .versionchange) {
        self.settle(exec);
    } else {
        // The drain is already scheduled and will settle us; just enter the
        // "committing" state. It isn't _settled yet, so we can't use that flag
        self._committing = true;
    }
}

pub fn abort(self: *IDBTransaction, exec: *Execution) !void {
    if (self._settled or self._committing) {
        return error.InvalidStateError;
    }

    self._aborted = true;
    self._settled = true;

    if (self._begun) {
        self._engine.rollback();
    }

    for (self._requests.items) |request| {
        request._op = .none;
        if (request._ready_state == .done) {
            continue;
        }
        request.setError(error.AbortError);
        request.deliver(exec) catch |err| {
            log.warn(.storage, "idb abort deliver", .{ .err = err });
        };
    }
    self.fire(exec, comptime .wrap("abort"), self._on_abort);
}

// Deliver pending requests, commit, then fire `complete` (or `abort` if the
// commit fails). Drives a transaction to a successful close — shared by the
// drain task and the open path's synchronous versionchange transaction.
pub fn settle(self: *IDBTransaction, exec: *Execution) void {
    self.deliverPending(exec);
    if (self._begun) {
        self._engine.commit() catch |err| {
            log.warn(.storage, "idb commit", .{ .err = err, .sqlite = self._engine.conn.lastError() });
            self._engine.rollback();
            self.fire(exec, comptime .wrap("abort"), self._on_abort);
            return;
        };
    }
    self.fire(exec, comptime .wrap("complete"), self._on_complete);
}

// "is this transaction still usable". Once settled or explicitly committing, it no
// longer accepts new requests.
pub fn assertActive(self: *const IDBTransaction) !void {
    if (self._settled or self._committing) {
        return error.TransactionInactiveError;
    }
}

pub fn ensureBegun(self: *IDBTransaction) !void {
    if (self._settled) {
        return error.TransactionInactiveError;
    }

    if (self._begun) {
        return;
    }
    try self._engine.begin();
    self._begun = true;
}

pub fn newRequest(self: *IDBTransaction) !*IDBRequest {
    const request = try IDBRequest.init(self._exec);
    request._txn = self;
    return request;
}

pub fn enqueue(self: *IDBTransaction, request: *IDBRequest) !void {
    try self._requests.append(self._exec.arena, request);
}

pub fn objectStore(self: *IDBTransaction, name: []const u8, exec: *Execution) !*IDBObjectStore {
    const database_id = self._db._database_id;
    const info = (try self._engine.objectStoreInfo(exec.arena, database_id, name)) orelse {
        return error.NotFound;
    };

    const owned_name = try exec.dupeString(name);
    return IDBObjectStore.init(self._engine, self, info.id, owned_name, info.key_path, info.auto_increment, exec);
}

pub fn getMode(self: *const IDBTransaction) Mode {
    return self._mode;
}

pub fn getDurability(self: *const IDBTransaction) Durability {
    return self._durability;
}

pub fn getDb(self: *IDBTransaction) *IDBDatabase {
    return self._db;
}

pub fn getObjectStoreNames(self: *IDBTransaction, exec: *Execution) !*DOMStringList {
    const arena = try exec.getArena(.small, "IDB.getObjectStoreNames");
    errdefer exec.releaseArena(arena);

    // A versionchange transaction spans every store; its set changes as the
    // upgrade creates/deletes stores, so resolve it live rather than caching.
    const names = if (self._mode == .versionchange)
        try self._engine.objectStoreNames(arena, self._db._database_id)
    else
        self._scope;

    const list = try arena.create(DOMStringList);
    list.* = .{ ._items = names, ._arena = arena };
    return list;
}

pub fn getOnComplete(self: *const IDBTransaction) ?js.Function.Global {
    return self._on_complete;
}

pub fn setOnComplete(self: *IDBTransaction, setter: ?FunctionSetter) void {
    self._on_complete = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const IDBTransaction) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *IDBTransaction, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnAbort(self: *const IDBTransaction) ?js.Function.Global {
    return self._on_abort;
}

pub fn setOnAbort(self: *IDBTransaction, setter: ?FunctionSetter) void {
    self._on_abort = getFunctionFromSetter(setter);
}

fn getFunctionFromSetter(setter: ?FunctionSetter) ?js.Function.Global {
    const s = setter orelse return null;
    return switch (s) {
        .func => |f| f,
        .anything => null,
    };
}

fn fire(self: *IDBTransaction, exec: *Execution, typ: lp.String, handler: ?js.Function.Global) void {
    self._settled = true;
    const event = Event.initTrusted(typ, null, exec.page) catch |err| {
        log.warn(.storage, "idb transaction event", .{ .err = err });
        return;
    };
    exec.dispatch(self.asEventTarget(), event, handler, .{ .context = "IDBTransaction" }) catch |err| {
        log.warn(.storage, "idb transaction dispatch", .{ .err = err });
    };
}

fn drain(ctx: *anyopaque) !?u32 {
    const self: *IDBTransaction = @ptrCast(@alignCast(ctx));
    if (self._settled) {
        // could have already been settled, e.g. via an abort)
        return null;
    }
    self.settle(self._exec);
    return null;
}

fn finalize(ctx: *anyopaque) void {
    const self: *IDBTransaction = @ptrCast(@alignCast(ctx));
    if (self._begun and !self._settled) {
        self._engine.rollback();
    }
}

fn deliverPending(self: *IDBTransaction, exec: *Execution) void {
    // exec.js.local must be non-null. In some cases it is (e.g. tx.commit()
    // called directly from JS), in others is isn't (drain schedule tasks).
    // Easier to explicitly create one and then restore whatever was there before.

    const prev_local = exec.js.local;
    defer exec.js.local = prev_local;

    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();

    exec.js.local = &ls.local;

    var i: usize = 0;
    while (i < self._requests.items.len) : (i += 1) {
        const request = self._requests.items[i];
        request.execute(exec) catch |err| {
            log.warn(.storage, "idb request execute", .{ .err = err });
            request.setError(err);
        };
        request.deliver(exec) catch |err| {
            log.warn(.storage, "idb request deliver", .{ .err = err });
        };
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBTransaction);

    pub const Meta = struct {
        pub const name = "IDBTransaction";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const mode = bridge.accessor(IDBTransaction.getMode, null, .{});
    pub const durability = bridge.accessor(IDBTransaction.getDurability, null, .{});
    pub const db = bridge.accessor(IDBTransaction.getDb, null, .{});
    pub const objectStoreNames = bridge.accessor(IDBTransaction.getObjectStoreNames, null, .{});
    pub const objectStore = bridge.function(IDBTransaction.objectStore, .{});
    pub const abort = bridge.function(IDBTransaction.abort, .{});
    pub const commit = bridge.function(IDBTransaction.commit, .{});
    pub const oncomplete = bridge.accessor(IDBTransaction.getOnComplete, IDBTransaction.setOnComplete, .{});
    pub const onerror = bridge.accessor(IDBTransaction.getOnError, IDBTransaction.setOnError, .{});
    pub const onabort = bridge.accessor(IDBTransaction.getOnAbort, IDBTransaction.setOnAbort, .{});
};
