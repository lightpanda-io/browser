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

// There's at least 1 instance of this at both ends: the page and the worker.
// They are all just views into a single ServiceWorkerGlobalScope which holds
// all the state. The ServiceWorker just holds its own event registration.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");
const ServiceWorkerGlobalScope = @import("ServiceWorkerGlobalScope.zig");

const log = lp.log;
const Execution = js.Execution;

const ServiceWorker = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_exec: *Execution,
// Null once the scope is gone. Reports as `redundant` in that case
_scope: ?*ServiceWorkerGlobalScope,
_on_state_change: ?js.Function.Global = null,

pub const State = enum {
    parsed,
    installing,
    installed,
    activating,
    activated,
    redundant,

    pub fn toString(self: State) []const u8 {
        return switch (self) {
            .parsed => "parsed",
            .installing => "installing",
            .installed => "installed",
            .activating => "activating",
            .activated => "activated",
            .redundant => "redundant",
        };
    }
};

pub fn init(scope: *ServiceWorkerGlobalScope, exec: *Execution) !*ServiceWorker {
    return exec._factory.eventTargetWithAllocator(exec.arena, ServiceWorker{
        ._proto = undefined,
        ._exec = exec,
        ._scope = scope,
    });
}

pub fn detach(self: *ServiceWorker) void {
    self._scope = null;
}

pub fn asEventTarget(self: *ServiceWorker) *EventTarget {
    return self._proto;
}

pub fn getScriptURL(self: *const ServiceWorker) []const u8 {
    const scope = self._scope orelse return "";
    return scope._proto.url;
}

pub fn getState(self: *const ServiceWorker) State {
    const scope = self._scope orelse return .redundant;
    return scope._state;
}

pub fn postMessage(self: *ServiceWorker, data: js.Value) !void {
    const scope = self._scope orelse return;
    return scope.receiveMessage(data);
}

pub fn stateChanged(self: *ServiceWorker) void {
    const exec = self._exec;
    if (exec.hasDirectListeners(self._proto, "statechange", self._on_state_change) == false) {
        return;
    }

    self.scheduleStateChange() catch |err| {
        log.warn(.browser, "SW statechange", .{ .err = err });
    };
}

fn scheduleStateChange(self: *ServiceWorker) !void {
    const exec = self._exec;

    const arena = try exec.getArena(.tiny, "ServiceWorker.statechange");
    errdefer arena.release();

    const callback = try arena.create(StateChangeCallback);
    callback.* = .{ .worker = self, .arena = arena };

    try exec.js.scheduler.add(callback, StateChangeCallback.run, 0, .{
        .name = "ServiceWorker.statechange",
        .finalizer = StateChangeCallback.cancelled,
    });
}
pub fn getOnStateChange(self: *const ServiceWorker) ?js.Function.Global {
    return self._on_state_change;
}

pub fn setOnStateChange(self: *ServiceWorker, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_state_change = WorkerGlobalScope.getFunctionFromSetter(setter);
}

const StateChangeCallback = struct {
    arena: *lp.Arena,
    worker: *ServiceWorker,

    fn cancelled(ctx: *anyopaque) void {
        const self: *StateChangeCallback = @ptrCast(@alignCast(ctx));
        self.arena.release();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *StateChangeCallback = @ptrCast(@alignCast(ctx));
        defer self.arena.release();

        const worker = self.worker;
        const exec = worker._exec;
        const event = (try Event.initTrusted(comptime .wrap("statechange"), .{
            .bubbles = false,
            .cancelable = false,
        }, exec.page));

        try exec.dispatch(worker._proto, event, worker._on_state_change, .{
            .context = "ServiceWorker.statechange",
        });
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(ServiceWorker);

    pub const Meta = struct {
        pub const name = "ServiceWorker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const scriptURL = bridge.accessor(ServiceWorker.getScriptURL, null, .{});
    pub const state = bridge.accessor(ServiceWorker.getState, null, .{});
    pub const postMessage = bridge.function(ServiceWorker.postMessage, .{});
    pub const onstatechange = bridge.accessor(ServiceWorker.getOnStateChange, ServiceWorker.setOnStateChange, .{});
};
