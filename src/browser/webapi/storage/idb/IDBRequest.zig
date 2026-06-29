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
const IDBDatabase = @import("IDBDatabase.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const IDBVersionChangeEvent = @import("IDBVersionChangeEvent.zig");

const Execution = js.Execution;
const FunctionSetter = idb.FunctionSetter;

const IDBRequest = @This();

_proto: *EventTarget,
_result: Result = .none,
_error: ?anyerror = null,
_txn: ?*IDBTransaction = null,
_ready_state: ReadyState = .pending,

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
    none,
    value: js.Value.Global, // the result of a get/add/put
    database: *IDBDatabase, // the result of an open
};

pub fn init(exec: *Execution) !*IDBRequest {
    return exec._factory.eventTarget(IDBRequest{ ._proto = undefined });
}

pub fn asEventTarget(self: *IDBRequest) *EventTarget {
    return self._proto;
}

pub fn setValueResult(self: *IDBRequest, value: js.Value) !void {
    self._result = .{ .value = try value.persist() };
}

pub fn setDatabaseResult(self: *IDBRequest, database: *IDBDatabase) void {
    self._result = .{ .database = database };
}

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

pub fn getResult(self: *const IDBRequest) !Result {
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBRequest);

    pub const Meta = struct {
        pub const name = "IDBRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const readyState = bridge.accessor(IDBRequest.getReadyState, null, .{});
    pub const result = bridge.accessor(IDBRequest.getResult, null, .{ .null_as_undefined = true });
    pub const transaction = bridge.accessor(IDBRequest.getTransaction, null, .{ .null_as_undefined = true });
    pub const @"error" = bridge.accessor(IDBRequest.getError, null, .{ .null_as_undefined = true });
    pub const onsuccess = bridge.accessor(IDBRequest.getOnSuccess, IDBRequest.setOnSuccess, .{});
    pub const onerror = bridge.accessor(IDBRequest.getOnError, IDBRequest.setOnError, .{});
    pub const onupgradeneeded = bridge.accessor(IDBRequest.getOnUpgradeNeeded, IDBRequest.setOnUpgradeNeeded, .{});
};
