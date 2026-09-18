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

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");

const Worker = @import("Worker.zig");
const EventTarget = @import("EventTarget.zig");
const ServiceWorker = @import("ServiceWorker.zig");
const ServiceWorkerGlobalScope = @import("ServiceWorkerGlobalScope.zig");
const ServiceWorkerRegistration = @import("ServiceWorkerRegistration.zig");

const log = lp.log;

const ServiceWorkerContainer = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_frame: *Frame,

// One per scope this container has registered
_registrations: std.ArrayList(*ServiceWorkerRegistration) = .empty,

_ready: ?js.Promise.Global = null,
_ready_resolver: ?js.PromiseResolver.Global = null,

const RegisterOptions = struct {
    scope: ?[]const u8 = null,
    type: Worker.WorkerType = .classic,
    updateViaCache: ?[]const u8 = null,
};

pub fn init(frame: *Frame) !*ServiceWorkerContainer {
    const self = try frame._factory.eventTargetWithAllocator(frame.arena, ServiceWorkerContainer{
        ._proto = undefined,
        ._frame = frame,
    });
    return self;
}

// Called from Frame.deinit
pub fn detach(self: *ServiceWorkerContainer) void {
    for (self._registrations.items) |registration| {
        registration.detach();
    }
    self._registrations.clearRetainingCapacity();

    if (self._ready_resolver) |resolver| {
        self._ready_resolver = null;
        resolver.release();
    }
    if (self._ready) |promise| {
        self._ready = null;
        promise.release();
    }
}

pub fn asEventTarget(self: *ServiceWorkerContainer) *EventTarget {
    return self._proto;
}

// Called by a worker once it reaches `activated`.
pub fn workerActivated(self: *ServiceWorkerContainer) void {
    if (self._ready_resolver == null) {
        // Nobody waiting: `ready` was never asked for, or has already settled.
        return;
    }

    self.scheduleReady() catch |err| {
        log.warn(.browser, "SWC ready", .{ .err = err });
    };
}

fn scheduleReady(self: *ServiceWorkerContainer) !void {
    const frame = self._frame;

    const arena = try frame._session.getArena(.tiny, "ServiceWorkerContainer.ready");
    errdefer arena.release();

    const callback = try arena.create(ReadyCallback);
    callback.* = .{ .container = self, .arena = arena };

    try frame.js.scheduler.add(callback, ReadyCallback.run, 0, .{
        .name = "ServiceWorkerContainer.ready",
        .finalizer = ReadyCallback.cancelled,
    });
}

pub fn register(self: *ServiceWorkerContainer, url: []const u8, options: ?RegisterOptions, frame: *Frame) !js.Promise {
    const resolver = frame.js.local.?.createPromiseResolver();

    const opts = options orelse RegisterOptions{};
    const script_url = URL.resolve(frame.local_arena, frame.base(), url, .{ .encoding = frame.charset }) catch {
        resolver.rejectError("ServiceWorkerContainer.register", .{ .type_error = "Failed to resolve script URL" });
        return resolver.promise();
    };

    // A worker may only be registered by, and control, its own origin.
    if (frame.isSameOrigin(script_url) == false) {
        resolver.reject("ServiceWorkerContainer.register", @import("DOMException.zig").init(
            "The origin of the provided scriptURL does not match the current origin.",
            "SecurityError",
        ));
        return resolver.promise();
    }

    const scope_url = blk: {
        const raw = opts.scope orelse blk2: {
            // A registration's default scope is the script's own directory.
            const end = std.mem.lastIndexOfScalar(u8, script_url, '/') orelse break :blk2 script_url;
            break :blk2 script_url[0 .. end + 1];
        };

        break :blk URL.resolve(frame.local_arena, frame.base(), raw, .{ .encoding = frame.charset }) catch {
            resolver.rejectError("ServiceWorkerContainer.register", .{ .type_error = "Failed to resolve scope URL" });
            return resolver.promise();
        };
    };

    const scope = ServiceWorkerGlobalScope.getOrCreate(frame, script_url, scope_url, opts.type) catch |err| {
        log.err(.browser, "SWC register", .{ .url = script_url, .err = err });
        resolver.rejectError("ServiceWorkerContainer.register", .{ .type_error = "Failed to register a ServiceWorker" });
        return resolver.promise();
    };

    const registration = try self.track(scope);
    resolver.resolve("ServiceWorkerContainer.register", registration);
    return resolver.promise();
}

fn track(self: *ServiceWorkerContainer, scope: *ServiceWorkerGlobalScope) !*ServiceWorkerRegistration {
    for (self._registrations.items) |registration| {
        if (registration._scope == scope) {
            return registration;
        }
    }

    const frame = self._frame;
    const registration = try ServiceWorkerRegistration.init(scope, self, &frame.js.execution);
    errdefer registration.detach();
    try self._registrations.append(frame.arena, registration);

    if (scope.hasActiveWorker()) {
        self.workerActivated();
    }

    return registration;
}

// For now, always null: we never dispatch fetch events.
pub fn getController(_: *ServiceWorkerContainer) ?*ServiceWorker {
    return null;
}

pub fn getReady(self: *ServiceWorkerContainer, exec: *const js.Execution) !js.Promise {
    if (self._ready != null) {
        return exec.js.toLocal(self._ready).?;
    }

    const resolver = exec.js.local.?.createPromiseResolver();
    const promise = resolver.promise();
    self._ready = try promise.persist();

    if (self.activeRegistration()) |registration| {
        // already have an active worker, resolve immediately.
        resolver.resolve("ServiceWorkerContainer.ready", registration);
    } else {
        self._ready_resolver = try resolver.persist();
    }
    return promise;
}

pub fn getRegistration(self: *ServiceWorkerContainer, url: ?[]const u8, frame: *Frame) !js.Promise {
    const resolver = frame.js.local.?.createPromiseResolver();

    const client_url = if (url) |u|
        URL.resolve(frame.local_arena, frame.base(), u, .{ .encoding = frame.charset }) catch {
            resolver.resolve("ServiceWorkerContainer.getRegistration", {});
            return resolver.promise();
        }
    else
        frame.url;

    if (self.matchScope(false, client_url)) |registration| {
        resolver.resolve("ServiceWorkerContainer.getRegistration", registration);
        return resolver.promise();
    }

    // Resolves with undefined when nothing matches.
    resolver.resolve("ServiceWorkerContainer.getRegistration", {});
    return resolver.promise();
}

pub fn getRegistrations(self: *ServiceWorkerContainer, exec: *const js.Execution) !js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();

    var registrations: std.ArrayList(*ServiceWorkerRegistration) = try .initCapacity(exec.local_arena, self._registrations.items.len);
    for (self._registrations.items) |registration| {
        if (registration._scope == null) {
            continue;
        }
        registrations.appendAssumeCapacity(registration);
    }

    resolver.resolve("ServiceWorkerContainer.getRegistrations", registrations.items);
    return resolver.promise();
}

// The registration with an active worker whose scope covers this frame's URL.
fn activeRegistration(self: *ServiceWorkerContainer) ?*ServiceWorkerRegistration {
    return self.matchScope(true, self._frame.url);
}

// The registration whose scope covers `client_url`, longest scope winning.
fn matchScope(self: *ServiceWorkerContainer, only_active: bool, client_url: []const u8) ?*ServiceWorkerRegistration {
    var best_len: usize = 0;
    var best: ?*ServiceWorkerRegistration = null;

    for (self._registrations.items) |registration| {
        const scope = registration._scope orelse continue;
        if (only_active and scope.hasActiveWorker() == false) {
            continue;
        }
        const scope_url = scope._scope_url;
        if (std.mem.startsWith(u8, client_url, scope_url) == false) {
            continue;
        }
        if (best == null or scope_url.len > best_len) {
            best = registration;
            best_len = scope_url.len;
        }
    }
    return best;
}

// Messages from a worker are delivered as soon as they're posted
pub fn startMessages(_: *ServiceWorkerContainer) void {}

const ReadyCallback = struct {
    arena: *lp.Arena,
    container: *ServiceWorkerContainer,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReadyCallback = @ptrCast(@alignCast(ctx));
        self.arena.release();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReadyCallback = @ptrCast(@alignCast(ctx));
        defer self.arena.release();

        const container = self.container;
        const resolver = container._ready_resolver orelse return null;
        const registration = container.activeRegistration() orelse return null;

        // clear this so we don't resolve again
        container._ready_resolver = null;
        defer resolver.release();

        var ls: js.Local.Scope = undefined;
        container._frame.js.localScope(&ls);
        defer ls.deinit();

        ls.toLocal(resolver).resolve("ServiceWorkerContainer.ready", registration);
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(ServiceWorkerContainer);

    pub const Meta = struct {
        pub const name = "ServiceWorkerContainer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const controller = bridge.accessor(ServiceWorkerContainer.getController, null, .{});
    pub const ready = bridge.accessor(ServiceWorkerContainer.getReady, null, .{});
    pub const register = bridge.function(ServiceWorkerContainer.register, .{});
    pub const getRegistration = bridge.function(ServiceWorkerContainer.getRegistration, .{});
    pub const getRegistrations = bridge.function(ServiceWorkerContainer.getRegistrations, .{});
    pub const startMessages = bridge.function(ServiceWorkerContainer.startMessages, .{});

    // A worker has no way to reach a client yet, so the API is missing things
    // like onmessage for now
};

const testing = @import("../../testing.zig");
test "WebApi: ServiceWorker" {
    // The throwing-worker and cross-origin cases log at error level on purpose.
    testing.silenceLog(&.{ .http, .browser });
    try testing.htmlRunner("service_worker/service_worker.html", .{
        .timeout_ms = 8000,
        .experimental_features = .{ .serviceworker = true },
    });
}

test "WebApi: ServiceWorker disabled" {
    try testing.htmlRunner("service_worker/disabled.html", .{ .timeout_ms = 8000 });
}
