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
const IDBDatabase = @import("IDBDatabase.zig");
const IDBRequest = @import("IDBRequest.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");
const DOMStringList = @import("../../collections.zig").DOMStringList;

const log = lp.log;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const FunctionSetter = idb.FunctionSetter;
const IS_DEBUG = @import("builtin").mode == .Debug;

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

// The transaction owns everything created under it — requests, stores,
// indexes, cursors, encoded keys, pending write values — on a pooled arena,
// released when `_rc` drops to zero. Refs: one per live JS wrapper of any
// owned object, one while a drain task is scheduled, one while parked on the
// engine's connection gate (gate ownership needs no ref of its own: it's only
// ever held while a drain task exists).
_rc: lp.RC(u32) = .{},
_arena: Allocator,

// v8 handles owned by the transaction, swept (reset) in deinit. Slots are
// arena-allocated so an early release and the sweep hit the same instance —
// a v8 Global reset is only idempotent through a single instance.
_globals: std.ArrayList(*js.Value.BareGlobal) = .empty,

// objectStore() must return the same object for a given name within one
// transaction (per spec); this also keeps repeated lookups off sqlite.
_stores: std.ArrayList(*IDBObjectStore) = .empty,

// request queue, swaps between &_queue_a and &_queue_b so that, as we drain, new
// requests are queued in the new queue and will be processed on the next drain
_queue: *std.ArrayList(*IDBRequest),
_queue_a: std.ArrayList(*IDBRequest) = .empty,
_queue_b: std.ArrayList(*IDBRequest) = .empty,

_begun: bool = false,
_settled: bool = false,
_aborted: bool = false,
_committing: bool = false,
_error: ?anyerror = null,
_gate_waiter: Engine.GateWaiter,
// A transaction is only active for one execution of a Scheduler's task. We
// capture the scheduler's generation here and reject any request made in a
// later generation (see assertActive).
_active_turn: u64 = 0,

// The transaction can be freed when v8 doesn't reference it (or any child,
// e.g. an IDBRequest), when we have no scheduled drain AND when we aren't
// parked in the Engine's wait gate. This last one we track explicitly so
// that, when Engine.detach cancels us, we know whether the registration held
// a pin (parked) or the drain task does (owner).
_parked: bool = false,

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

pub fn init(db: *IDBDatabase, mode: Mode, durability: Durability, exec: *Execution) !*IDBTransaction {
    const arena = try exec.getArena(.small, "IDBTransaction");

    const self = blk: {
        errdefer exec.releaseArena(arena);
        const s = try exec._factory.eventTargetWithAllocator(arena, IDBTransaction{
            ._proto = undefined,
            ._exec = exec,
            ._db = db,
            ._engine = db._engine,
            ._mode = mode,
            ._arena = arena,
            ._durability = durability,
            ._active_turn = exec.js.scheduler.generation,
            ._queue = undefined,
            ._gate_waiter = undefined,
        });
        s._queue = &s._queue_a;
        s._gate_waiter = .{ .ctx = exec.js, .wake = resumeDrain, .cancel = cancelGate };
        break :blk s;
    };

    try self.scheduleDrain();
    return self;
}

// We need a "special" transaction for upgradeneeded. It has no drain task and
// no gate registration, so it starts with zero refs: the caller (the open
// path) must pin it for the duration of the upgrade.
pub fn initVersionChange(db: *IDBDatabase, exec: *Execution) !*IDBTransaction {
    const arena = try exec.getArena(.small, "IDBTransaction");
    errdefer exec.releaseArena(arena);

    const self = try exec._factory.eventTargetWithAllocator(arena, IDBTransaction{
        ._proto = undefined,
        ._exec = exec,
        ._db = db,
        ._engine = db._engine,
        ._mode = .versionchange,
        ._arena = arena,
        ._begun = true,
        ._active_turn = exec.js.scheduler.generation,
        ._queue = undefined,
        ._gate_waiter = undefined,
    });
    self._queue = &self._queue_a;
    // A versionchange transaction never contends for the gate (the open path
    // holds it); keep the node well-formed so releaseGate's owner check no-ops.
    self._gate_waiter = .{ .ctx = exec.js, .wake = resumeDrain, .cancel = cancelGate };
    return self;
}

pub fn deinit(self: *IDBTransaction, page: *Page) void {
    if (comptime IS_DEBUG) {
        // Pins hold refs, so the last release can't happen while parked (nor
        // while a drain task is scheduled).
        std.debug.assert(self._parked == false);
    }
    for (self._globals.items) |slot| {
        slot.deinit();
    }
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *IDBTransaction) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *IDBTransaction, page: *Page) void {
    self._rc.release(self, page);
}

// Persist a JS value with the transaction's lifetime: the handle is reset when the
// transaction's memory is released — or earlier, by calling deinit() on the
// returned slot (the sweep's second reset is then a no-op).
pub fn persist(self: *IDBTransaction, value: js.Value) !*js.Value.BareGlobal {
    const slot = try self._arena.create(js.Value.BareGlobal);
    try self._globals.append(self._arena, slot);
    slot.* = value.bare();
    return slot;
}

pub fn dupe(self: *IDBTransaction, value: []const u8) ![]const u8 {
    if (lp.String.intern(value)) |v| {
        return v;
    }
    return self._arena.dupe(u8, value);
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

// JS-facing, no reason
pub fn abort(self: *IDBTransaction, exec: *Execution) !void {
    return self.abortWith(exec, null);
}

// Internal, optional reason
pub fn abortWith(self: *IDBTransaction, exec: *Execution, reason: ?anyerror) error{InvalidStateError}!void {
    if (self._settled or self._committing) {
        return error.InvalidStateError;
    }

    self._aborted = true;
    self._settled = true;
    self._error = reason;

    // An aborted upgrade reverts the schema: stores and indexes created during
    // it no longer exist, so handles the caller still holds must report deleted.
    if (self._mode == .versionchange) {
        for (self._stores.items) |store| {
            if (store._created) {
                store._deleted = true;
            }
            for (store._indexes.items) |idx| {
                if (idx._created) {
                    idx._deleted = true;
                }
            }
        }
    }

    if (self._begun) {
        self._engine.rollback();
        self._begun = false;
    }
    // No-op if we're parked rather than owner; the park pin is then released
    // by the eventual wake (drain's settled path) or a detach cancel.
    _ = self._engine.releaseGate(&self._gate_waiter);

    for ([_]*std.ArrayList(*IDBRequest){ &self._queue_a, &self._queue_b }) |queue| {
        for (queue.items, 0..) |request, i| {
            if (i != request._txn_index or request._op == .none) {
                continue;
            }
            request._op = .none;
            request.setError(error.AbortError);
            request.deliver(exec) catch |err| {
                log.warn(.storage, "idb abort deliver", .{ .err = err });
            };
        }
    }
    self.fire(exec, comptime .wrap("abort"), self._on_abort);
}

pub fn settle(self: *IDBTransaction, exec: *Execution) void {
    // Deliver batches until the queue stays empty — a handler may enqueue more.
    while (self.settleStep(exec)) {}
}

// One settle turn: deliver the pending batch of request events (handlers may
// enqueue more) and, once the queue stays empty, commit and fire `complete`.
// Returns true while more batches remain.
pub fn settleStep(self: *IDBTransaction, exec: *Execution) bool {
    if (comptime IS_DEBUG) {
        // non versionchange mode goes through the scheduler + drain
        std.debug.assert(self._mode == .versionchange);
    }

    if (self._settled) {
        return false;
    }

    if (self._queue.items.len > 0) {
        self.deliverBatch(exec);
        if (self._settled) {
            // a request handler settled this (e.g. called abort) mid-batch
            return false;
        }
        if (self._queue.items.len > 0) {
            return true;
        }
    }
    self.commitAndComplete(exec);
    return false;
}

// Commit the underlying sqlite transaction (if begun), release the connection
// gate, then fire `complete` — or `abort` if the commit fails.
fn commitAndComplete(self: *IDBTransaction, exec: *Execution) void {
    if (self._begun) {
        self._engine.commit() catch |err| {
            log.warn(.storage, "idb commit", .{ .err = err, .sqlite = self._engine.lastError() });
            self._engine.rollback();
            self._begun = false;
            _ = self._engine.releaseGate(&self._gate_waiter);
            self.fire(exec, comptime .wrap("abort"), self._on_abort);
            return;
        };
        self._begun = false;
    }
    _ = self._engine.releaseGate(&self._gate_waiter);
    self.fire(exec, comptime .wrap("complete"), self._on_complete);
}

// "is this transaction still usable". Once settled or explicitly committing, it
// no longer accepts new requests; nor does it outside its active turn (a request
// made from an unrelated task). The turn is stamped at creation (which covers
// the upgradeneeded dispatch for a versionchange transaction) and again by each
// delivered batch.
pub fn assertActive(self: *const IDBTransaction) !void {
    if (self._settled or self._committing) {
        return error.TransactionInactiveError;
    }
    if (self._active_turn != self._exec.js.scheduler.generation) {
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
    const request = try self._exec._factory.eventTargetWithAllocator(self._arena, IDBRequest{ ._proto = undefined });
    request._txn = .{ .owned = self };
    return request;
}

pub fn enqueue(self: *IDBTransaction, request: *IDBRequest) !void {
    request._txn_index = self._queue.items.len;
    try self._queue.append(self._arena, request);
}

pub fn objectStore(self: *IDBTransaction, name: []const u8) !*IDBObjectStore {
    for (self._stores.items) |store| {
        if (std.mem.eql(u8, store._name, name)) {
            return store;
        }
    }

    const database_id = self._db._database_id;
    const info = (try self._engine.objectStoreInfo(self._arena, database_id, name)) orelse {
        return error.NotFound;
    };

    const owned_name = try self.dupe(name);
    const store = try IDBObjectStore.init(self, info.id, owned_name, info.key_path, info.auto_increment);
    try self._stores.append(self._arena, store);
    return store;
}

// Register a store created during an upgrade so a later objectStore() returns
// the same object.
pub fn cacheStore(self: *IDBTransaction, store: *IDBObjectStore) !void {
    try self._stores.append(self._arena, store);
}

// A store was deleted during an upgrade; a later objectStore() must miss.
pub fn uncacheStore(self: *IDBTransaction, name: []const u8) void {
    for (self._stores.items, 0..) |store, i| {
        if (std.mem.eql(u8, store._name, name)) {
            store._deleted = true;
            _ = self._stores.swapRemove(i);
            return;
        }
    }
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
    // The list is refcounted and can outlive the transaction, so the scope
    // names are copied onto the list's own arena.
    const names = if (self._mode == .versionchange)
        try self._engine.objectStoreNames(arena, self._db._database_id)
    else blk: {
        const copy = try arena.alloc([]const u8, self._scope.len);
        for (self._scope, 0..) |name, i| {
            copy[i] = try arena.dupe(u8, name);
        }
        break :blk copy;
    };

    const list = try arena.create(DOMStringList);
    list.* = .{ ._items = names, ._arena = arena };
    return list;
}

pub fn getError(self: *const IDBTransaction) ?DOMException {
    const err = self._error orelse return null;
    const mapped: anyerror = switch (err) {
        error.Constraint => error.ConstraintError,
        else => err,
    };
    return DOMException.fromError(mapped) orelse DOMException.init(null, "UnknownError");
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

// Schedule the drain task, which pins the transaction until it runs to completion
// (or its scheduler finalizer runs).
fn scheduleDrain(self: *IDBTransaction) !void {
    self.acquireRef();
    errdefer self.releaseRef(self._exec.page);
    try self._exec.js.scheduler.add(self, drain, 0, .{
        .name = "IDBTransaction.drain",
        .finalizer = finalize,
    });
}

fn drain(ctx: *anyopaque) !?u32 {
    const self: *IDBTransaction = @ptrCast(@alignCast(ctx));
    const repeat = self.drainInner();
    if (repeat == null) {
        // The drain task is done; drop its pin. May free the transaction —
        // must be the last touch.
        self.releaseRef(self._exec.page);
    }
    return repeat;
}

fn drainInner(self: *IDBTransaction) ?u32 {
    if (self._settled) {
        // Already settled (e.g. via an abort, which released the gate; the
        // release here is a defensive no-op in that case).
        _ = self._engine.releaseGate(&self._gate_waiter);
        return null;
    }

    const exec = self._exec;

    if (self._queue.items.len > 0) {
        if (self._engine.acquireGate(&self._gate_waiter) == false) {
            // Parked: no drain task exists while we wait for the gate, and our
            // wrappers may all be collected, so the registration itself must
            // pin us until resumeDrain (or a detach cancel) unparks.
            self._parked = true;
            self.acquireRef();
            return null;
        }

        self.deliverBatch(exec);
        if (self._settled) {
            // a handler aborted us mid-delivery; abort() released the gate.
            return null;
        }
        if (self._queue.items.len > 0) {
            // handlers enqueued more — keep the gate and resume next turn.
            return 1;
        }
    }

    // Nothing left to deliver: commit and fire `complete` (releases the gate).
    self.commitAndComplete(exec);
    return null;
}

fn unpark(self: *IDBTransaction) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self._parked);
    }
    self._parked = false;
    self.releaseRef(self._exec.page);
}

// Scheduler wake-up: the gate was handed to us, so run the drain again.
fn resumeDrain(waiter: *Engine.GateWaiter) void {
    const self: *IDBTransaction = @fieldParentPtr("_gate_waiter", waiter);
    if (comptime IS_DEBUG) {
        std.debug.assert(self._mode != .versionchange);
    }

    defer self.unpark();
    self.scheduleDrain() catch |err| {
        // We were handed the gate; if we can't reschedule, hand it off so the
        // waiters behind us aren't stranded. Unpark may free self — last touch.
        log.warn(.storage, "idb resume drain", .{ .err = err });
        _ = self._engine.releaseGate(&self._gate_waiter);
    };
}

// Scheduler task finalizer: our context's scheduler is being torn down.
// Engine.detach normally ran first and already unlinked us from the gate; the
// gate handling here is a backstop for a scheduler reset without a detach.
// Never parked here — a parked transaction has no task to finalize.
fn finalize(ctx: *anyopaque) void {
    const self: *IDBTransaction = @ptrCast(@alignCast(ctx));
    if (self._begun and !self._settled) {
        self._engine.rollback();
        self._begun = false;
    }
    self._settled = true;
    _ = self._engine.releaseGate(&self._gate_waiter);
    // The task pin; may free the transaction — must be the last touch.
    self.releaseRef(self._exec.page);
}

// Engine.detach cancel: our context is going away; the unlink/hand-off is
// detach's job. The one site that runs in either gate state: parked, the
// registration held our pin; as owner, a drain task exists and its finalizer
// releases that pin instead.
fn cancelGate(waiter: *Engine.GateWaiter) void {
    const self: *IDBTransaction = @fieldParentPtr("_gate_waiter", waiter);
    if (self._begun) {
        self._engine.rollback();
        self._begun = false;
    }
    self._settled = true;
    if (self._parked == true) {
        self.unpark();
    }
}

// Deliver the requests queued as of now, one queue's worth. Requests enqueued
// by handlers during delivery go to the other queue and are handled on a later
// turn.
fn deliverBatch(self: *IDBTransaction, exec: *Execution) void {
    const batch = self._queue;
    // New requests now accumulate in the other queue.
    self._queue = if (batch == &self._queue_a) &self._queue_b else &self._queue_a;
    defer batch.clearRetainingCapacity();

    // exec.js.local must be non-null. In some cases it is (e.g. tx.commit()
    // called directly from JS), in others is isn't (drain schedule tasks).
    // Easier to explicitly create one and then restore whatever was there before.
    const prev_local = exec.js.local;
    defer exec.js.local = prev_local;

    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();

    exec.js.local = &ls.local;

    // The transaction is active for this batch's dispatch and the rest of this
    // task's turn (including the microtasks it queues). generation is constant
    // within a task, so stamp it once.
    self._active_turn = exec.js.scheduler.generation;

    for (batch.items) |request| {
        // A handler may have aborted the transaction mid-delivery; abort() already
        // delivered AbortError to the remaining requests, so stop here.
        if (self._settled) {
            return;
        }
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
    pub const @"error" = bridge.accessor(IDBTransaction.getError, null, .{ .null_as_undefined = true });
    pub const objectStore = bridge.function(IDBTransaction.objectStore, .{});
    pub const abort = bridge.function(IDBTransaction.abort, .{});
    pub const commit = bridge.function(IDBTransaction.commit, .{});
    pub const oncomplete = bridge.accessor(IDBTransaction.getOnComplete, IDBTransaction.setOnComplete, .{});
    pub const onerror = bridge.accessor(IDBTransaction.getOnError, IDBTransaction.setOnError, .{});
    pub const onabort = bridge.accessor(IDBTransaction.getOnAbort, IDBTransaction.setOnAbort, .{});
};
