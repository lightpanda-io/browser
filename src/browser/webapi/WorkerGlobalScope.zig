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

const js = @import("../js/js.zig");

const base64 = @import("encoding/base64.zig");
const Console = @import("Console.zig");
const Crypto = @import("Crypto.zig");
const EventTarget = @import("EventTarget.zig");
const Performance = @import("Performance.zig");

const WorkerGlobalScope = @This();

_proto: *EventTarget,
_console: Console = .init,
_crypto: Crypto = .init,
_performance: Performance,
_on_error: ?js.Function.Global = null,
_on_rejection_handled: ?js.Function.Global = null,
_on_unhandled_rejection: ?js.Function.Global = null,

pub fn asEventTarget(self: *WorkerGlobalScope) *EventTarget {
    return self._proto;
}

pub fn getSelf(self: *WorkerGlobalScope) *WorkerGlobalScope {
    return self;
}

pub fn getConsole(self: *WorkerGlobalScope) *Console {
    return &self._console;
}

pub fn getCrypto(self: *WorkerGlobalScope) *Crypto {
    return &self._crypto;
}

pub fn getPerformance(self: *WorkerGlobalScope) *Performance {
    return &self._performance;
}

pub fn getOnError(self: *const WorkerGlobalScope) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const WorkerGlobalScope) ?js.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const WorkerGlobalScope) ?js.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

pub fn btoa(_: *const WorkerGlobalScope, input: []const u8, exec: *js.Execution) ![]const u8 {
    return base64.encode(exec.call_arena, input);
}

pub fn atob(_: *const WorkerGlobalScope, input: []const u8, exec: *js.Execution) ![]const u8 {
    return base64.decode(exec.call_arena, input);
}

pub fn structuredClone(_: *const WorkerGlobalScope, value: js.Value) !js.Value {
    return value.structuredClone();
}

// TODO: importScripts - needs script loading infrastructure
// TODO: location - needs WorkerLocation
// TODO: navigator - needs WorkerNavigator
// TODO: Timer functions - need scheduler integration

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "WorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const self = bridge.accessor(WorkerGlobalScope.getSelf, null, .{});
    pub const console = bridge.accessor(WorkerGlobalScope.getConsole, null, .{});
    pub const crypto = bridge.accessor(WorkerGlobalScope.getCrypto, null, .{});
    pub const performance = bridge.accessor(WorkerGlobalScope.getPerformance, null, .{});

    pub const onerror = bridge.accessor(WorkerGlobalScope.getOnError, WorkerGlobalScope.setOnError, .{});
    pub const onrejectionhandled = bridge.accessor(WorkerGlobalScope.getOnRejectionHandled, WorkerGlobalScope.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(WorkerGlobalScope.getOnUnhandledRejection, WorkerGlobalScope.setOnUnhandledRejection, .{});

    pub const btoa = bridge.function(WorkerGlobalScope.btoa, .{});
    pub const atob = bridge.function(WorkerGlobalScope.atob, .{ .dom_exception = true });
    pub const structuredClone = bridge.function(WorkerGlobalScope.structuredClone, .{});

    // Return false since workers don't have secure-context-only APIs
    pub const isSecureContext = bridge.property(false, .{ .template = false });
};
