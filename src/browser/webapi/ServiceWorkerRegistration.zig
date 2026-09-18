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

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");
const ServiceWorker = @import("ServiceWorker.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");
const ServiceWorkerContainer = @import("ServiceWorkerContainer.zig");
const ServiceWorkerGlobalScope = @import("ServiceWorkerGlobalScope.zig");

const log = lp.log;
const Execution = js.Execution;

const ServiceWorkerRegistration = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_exec: *Execution,

// Null once the scope is gone
_scope: ?*ServiceWorkerGlobalScope,
_scope_url: []const u8,

_worker: ?*ServiceWorker = null,

// null when registered with the SWGC (the "worker side"). Set when registered
// on the "page side".
_container: ?*ServiceWorkerContainer,

// ServiceWorkerGlobalScope._registrations
_node: std.DoublyLinkedList.Node = .{},

_on_update_found: ?js.Function.Global = null,

pub fn init(scope: *ServiceWorkerGlobalScope, container: ?*ServiceWorkerContainer, exec: *Execution) !*ServiceWorkerRegistration {
    const self = try exec._factory.eventTargetWithAllocator(exec.arena, ServiceWorkerRegistration{
        ._proto = undefined,
        ._exec = exec,
        ._scope = scope,
        ._scope_url = try exec.arena.dupe(u8, scope._scope_url),
        ._container = container,
    });
    scope._registrations.append(&self._node);
    return self;
}

// Called from the scope when it's unregistered or torn down
pub fn detach(self: *ServiceWorkerRegistration) void {
    const scope = self._scope orelse return;
    self._scope = null;
    scope._registrations.remove(&self._node);
    if (self._worker) |w| {
        w.detach();
    }
}

pub fn stateChanged(self: *ServiceWorkerRegistration) void {
    if (self._worker) |w| {
        w.stateChanged();
    }
}

pub fn asEventTarget(self: *ServiceWorkerRegistration) *EventTarget {
    return self._proto;
}

pub fn getScope(self: *const ServiceWorkerRegistration) []const u8 {
    return self._scope_url;
}

pub fn getInstalling(self: *ServiceWorkerRegistration) !?*ServiceWorker {
    const scope = self._scope orelse return null;
    return switch (scope._state) {
        .parsed, .installing => try self.worker(scope),
        else => null,
    };
}

pub fn getWaiting(self: *ServiceWorkerRegistration) !?*ServiceWorker {
    const scope = self._scope orelse return null;
    return switch (scope._state) {
        .installed => try self.worker(scope),
        else => null,
    };
}

pub fn getActive(self: *ServiceWorkerRegistration) !?*ServiceWorker {
    const scope = self._scope orelse return null;
    return switch (scope._state) {
        .activating, .activated => try self.worker(scope),
        else => null,
    };
}

pub fn getUpdateViaCache(_: *const ServiceWorkerRegistration) []const u8 {
    // this is all we implement right now, and it still goes through the HTTP
    // cache like anything else for now.
    return "imports";
}

pub fn update(_: *ServiceWorkerRegistration, exec: *const Execution) !js.Promise {
    log.warn(.not_implemented, "SWR.update", .{});
    const resolver = exec.js.local.?.createPromiseResolver();
    resolver.resolve("ServiceWorkerRegistration.update", {});
    return resolver.promise();
}

pub fn unregister(self: *ServiceWorkerRegistration, exec: *const Execution) !js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();
    const was_registered = if (self._scope) |scope| scope.unregister() else false;
    resolver.resolve("ServiceWorkerRegistration.unregister", was_registered);
    return resolver.promise();
}

pub fn getOnUpdateFound(self: *const ServiceWorkerRegistration) ?js.Function.Global {
    return self._on_update_found;
}

pub fn setOnUpdateFound(self: *ServiceWorkerRegistration, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_update_found = WorkerGlobalScope.getFunctionFromSetter(setter);
}

pub fn worker(self: *ServiceWorkerRegistration, scope: *ServiceWorkerGlobalScope) !*ServiceWorker {
    if (self._worker) |w| {
        return w;
    }
    const w = try ServiceWorker.init(scope, self._exec);
    self._worker = w;
    return w;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ServiceWorkerRegistration);

    pub const Meta = struct {
        pub const name = "ServiceWorkerRegistration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const scope = bridge.accessor(ServiceWorkerRegistration.getScope, null, .{});
    pub const installing = bridge.accessor(ServiceWorkerRegistration.getInstalling, null, .{});
    pub const waiting = bridge.accessor(ServiceWorkerRegistration.getWaiting, null, .{});
    pub const active = bridge.accessor(ServiceWorkerRegistration.getActive, null, .{});
    pub const updateViaCache = bridge.accessor(ServiceWorkerRegistration.getUpdateViaCache, null, .{});
    pub const update = bridge.function(ServiceWorkerRegistration.update, .{});
    pub const unregister = bridge.function(ServiceWorkerRegistration.unregister, .{});
    pub const onupdatefound = bridge.accessor(ServiceWorkerRegistration.getOnUpdateFound, ServiceWorkerRegistration.setOnUpdateFound, .{});
};
