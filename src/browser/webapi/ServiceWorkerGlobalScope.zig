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
const Transfer = @import("../../network/HttpClient.zig").Transfer;

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");

const Worker = @import("Worker.zig");
const ServiceWorker = @import("ServiceWorker.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");
const ServiceWorkerRegistration = @import("ServiceWorkerRegistration.zig");

const CookieStore = @import("storage/CookieStore.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ExtendableEvent = @import("event/ExtendableEvent.zig");

const log = lp.log;
const String = lp.String;

const ServiceWorkerGlobalScope = @This();

pub const Proto = WorkerGlobalScope;

const ScriptLoad = struct {
    arena: *lp.Arena,
    buffer: std.ArrayList(u8) = .empty,
    transfer: ?*Transfer = null,
};

_proto: *WorkerGlobalScope,
_arena: *lp.Arena,

_scope_url: []const u8,
_state: ServiceWorker.State = .parsed,

// The in-flight fetch of the initial script.
_script_load: ?ScriptLoad = null,

// The registration  associated with this side, if any
_self_registration: ?*ServiceWorkerRegistration = null,

_cookie_store: ?*CookieStore = null,
_on_install: ?js.Function.Global = null,
_on_activate: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,

// Our event dispatching is more complicated, because it can be held by an
// arbitrary JS promise (ExtendableEvent.waitUntil). So we create this, hold it
// (aka acquireRef() it), dispatch it when the promise resolve, and then
// releaseRef().
_pending_event: ?*ExtendableEvent = null,

// Every SWR related to us. If 2 frames register the same URL, that's 2 SWR
// minimum (on the page-side, they are immediately created since that's what
// register(URL) returns). + 2 optional SWR, one for each _self_registration
// (a few fields up) which is lazily created on demand (on the "worker side").
_registrations: std.DoublyLinkedList = .{},

// Messages posted before the script finished evaluating. Same reasoning as
// DedicatedWorkerGlobalScope: a message that arrives before the script has had
// a chance to register onmessage would otherwise be dropped silently.
_pending_messages: std.ArrayList(?js.Value.Global) = .empty,

// Never created directly, always via the getOrCreate factory
fn init(
    frame: *Frame,
    script_url: [:0]const u8,
    scope_url: []const u8,
    worker_type: Worker.WorkerType,
) !*ServiceWorkerGlobalScope {
    const session = frame._session;

    const arena = try session.getArena(.small, "ServiceWorker");
    errdefer arena.release();

    const owned_url = try arena.dupeZ(u8, script_url);
    const frame_id = session.nextFrameId();
    const loader_id = session.nextLoaderId();

    const self = try WorkerGlobalScope.init(
        arena.allocator(),
        owned_url,
        .service,
        ServiceWorkerGlobalScope{
            ._proto = undefined,
            ._arena = arena,
            ._scope_url = try arena.dupe(u8, scope_url),
        },
        worker_type == .module,
        frame_id,
        loader_id,
        frame,
    );
    const proto = self._proto;
    errdefer proto.deinit();

    self._script_load = .{ .arena = try session.getArena(.large, "ServiceWorker.script") };
    errdefer self.releaseScriptLoad();

    const transfer = proto.newRequest(.{
        .ctx = self,
        .method = .GET,
        .url = owned_url,
        .resource_type = .worker,
        .origin = frame.origin,
        .credentials_mode = .same_origin,
        .request_mode = .same_origin,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        log.err(.browser, "SWGS request", .{ .url = owned_url, .err = err });
        return err;
    };
    self._script_load.?.transfer = transfer;
    transfer.submit() catch |err| {
        log.err(.browser, "SWGS request", .{ .url = owned_url, .err = err });
        return err;
    };
    return self;
}

// Called from Page.deinit of the owning (creating) page.
pub fn deinit(self: *ServiceWorkerGlobalScope) void {
    if (self._script_load) |*load| {
        if (load.transfer) |transfer| {
            load.transfer = null;
            transfer.cancel(); // re-enters httpErrorCallback -> releaseScriptLoad
        }
    }
    for (self._pending_messages.items) |data_| {
        if (data_) |d| {
            d.release();
        }
    }

    self.detachRegistrations();
    self.releasePendingEvent();

    self.releaseScriptLoad();
    _ = self.unregister();
    self._proto.deinit();
    self._arena.release();
}

pub fn getOrCreate(
    frame: *Frame,
    script_url: [:0]const u8,
    scope_url: []const u8,
    worker_type: Worker.WorkerType,
) !*ServiceWorkerGlobalScope {
    const session = frame._session;
    if (session.service_workers.get(scope_url)) |existing| {
        if (std.mem.eql(u8, existing._proto.url, script_url)) {
            return existing;
        }
        // No update pipeline yet: a different script for the same scope
        // replaces the registration outright. The old worker goes redundant and
        // every realm's registration for it is detached.
        _ = existing.unregister();
    }

    const self = try init(frame, script_url, scope_url, worker_type);
    errdefer self.deinit();

    const page = frame.page;
    try page.service_workers.append(page.frame_arena, self);
    errdefer _ = page.service_workers.pop();

    try session.service_workers.put(session.arena.allocator(), self._scope_url, self);
    return self;
}

pub fn unregister(self: *ServiceWorkerGlobalScope) bool {
    const session = self._proto._session;
    const entry = session.service_workers.getEntry(self._scope_url) orelse return false;

    if (entry.value_ptr.* != self) {
        // scope was re-used by another worker, we don't know it anymore
        return false;
    }

    session.service_workers.removeByPtr(entry.key_ptr);
    self.setState(.redundant);
    self.detachRegistrations();
    return true;
}

fn detachRegistrations(self: *ServiceWorkerGlobalScope) void {
    while (self._registrations.first) |node| {
        const registration: *ServiceWorkerRegistration = @alignCast(@fieldParentPtr("_node", node));
        registration.detach(); // removes from self._registrations
    }
}

pub fn hasActiveWorker(self: *const ServiceWorkerGlobalScope) bool {
    return self._state == .activating or self._state == .activated;
}

fn httpHeaderCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(transfer.req.ctx));

    const status = transfer.responseStatus() orelse return .abort;
    if (status < 200 or status >= 300) {
        log.warn(.browser, "SWGS status", .{ .url = self._proto.url, .status = status });
        return .abort;
    }

    const load = &self._script_load.?;
    try load.buffer.ensureTotalCapacityPrecise(load.arena.allocator(), transfer.bodyLen());

    return .proceed;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(transfer.req.ctx));
    const load = &self._script_load.?;
    try load.buffer.appendSlice(load.arena.allocator(), data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    // clear immediately, we 100% don't own this anymore
    self._script_load.?.transfer = null;
    defer self.releaseScriptLoad();

    if (comptime lp.IS_DEBUG) {
        log.info(.browser, "SWGS fetch done", .{
            .url = self._proto.url,
            .len = self._script_load.?.buffer.items.len,
        });
    }

    try self.loadInitialScript(self._script_load.?.buffer.items);
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self.releaseScriptLoad();
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self.releaseScriptLoad();

    if (err != error.TransferCanceled) {
        log.err(.browser, "SWGS fetch error", .{ .url = self._proto.url, .err = err });
    }

    self.setState(.redundant);
    _ = self.unregister();

    // The script will never run, so nothing can ever handle these.
    for (self._pending_messages.items) |cloned_data| {
        if (cloned_data) |d| d.release();
    }
    self._pending_messages.clearRetainingCapacity();
}

fn loadInitialScript(self: *ServiceWorkerGlobalScope, script: []const u8) !void {
    const js_context = self._proto.js;

    if (js_context.env.terminatePending()) {
        return;
    }

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const url = self._proto.url;
    var evaluated = true;
    if (self._proto._is_module) {
        js_context.module(false, &ls.local, script, url, true) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }
            js_context.page.recordJsError(err);
            const caught = try_catch.caughtOrError(self._script_load.?.arena.allocator(), err);
            log.err(.browser, "SWGS module error", .{ .url = url, .caught = caught });
            evaluated = false;
        };
    } else {
        ls.local.eval(script, url) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }
            js_context.page.recordJsError(err);
            const caught = try_catch.caughtOrError(self._script_load.?.arena.allocator(), err);
            log.err(.browser, "SWGS script error", .{ .url = url, .caught = caught });
            evaluated = false;
        };
    }

    ls.local.runMacrotasks();

    if (evaluated == false) {
        self.setState(.redundant);
        _ = self.unregister();
        self.drainPendingMessages();
        return;
    }

    self.beginInstall();
    self.drainPendingMessages();
}

fn releaseScriptLoad(self: *ServiceWorkerGlobalScope) void {
    const load = self._script_load orelse return;
    self._script_load = null;
    load.arena.release();
}

fn beginInstall(self: *ServiceWorkerGlobalScope) void {
    self.setState(.installing);
    self.dispatchExtendable(comptime .wrap("install"), self._on_install, struct {
        fn done(ctx: *anyopaque) void {
            const s: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
            s.releasePendingEvent();
            s.setState(.installed);
            s.beginActivate();
        }
    }.done) catch |err| {
        log.warn(.browser, "SWGS install", .{ .url = self._proto.url, .err = err });
        self.beginActivate();
    };
}

fn beginActivate(self: *ServiceWorkerGlobalScope) void {
    if (self._state == .redundant) {
        // Unregistered (or replaced) while install's waitUntil was pending.
        return;
    }
    self.setState(.activating);
    self.dispatchExtendable(comptime .wrap("activate"), self._on_activate, struct {
        fn done(ctx: *anyopaque) void {
            const s: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
            s.releasePendingEvent();
            s.finishActivation();
        }
    }.done) catch |err| {
        log.warn(.browser, "SWGS activate", .{ .url = self._proto.url, .err = err });
        self.finishActivation();
    };
}

fn finishActivation(self: *ServiceWorkerGlobalScope) void {
    self.setState(.activated);

    // Containers only *schedule* the `ready` resolution, they don't execute JS
    // directly, i.e. no mutation of `_registrations` is possible here.
    var node = self._registrations.first;
    while (node) |n| : (node = n.next) {
        const registration: *ServiceWorkerRegistration = @alignCast(@fieldParentPtr("_node", n));
        if (registration._container) |container| {
            // registration._container is only set for SWR from the "page side".
            // so this is us signaling the page-side container of the activation.
            container.workerActivated();
        }
    }
}

fn dispatchExtendable(
    self: *ServiceWorkerGlobalScope,
    typ: String,
    handler: ?js.Function.Global,
    comptime on_done: fn (ctx: *anyopaque) void,
) !void {
    const wgs = self._proto;
    const event = try ExtendableEvent.initTrusted(typ, .{
        .bubbles = false,
        .cancelable = false,
    }, wgs.page);

    const base = event.asEvent();

    base.acquireRef(); // on_done is responsible for releasing this
    self._pending_event = event;
    errdefer self.releasePendingEvent();

    try wgs.dispatch(wgs.asEventTarget(), base, handler, .{ .context = "ServiceWorkerGlobalScope lifecycle" });

    // Seal only after the handlers have run, so a synchronous waitUntil is
    // counted before an empty pending set can complete the phase.
    event.seal(.{ .ctx = self, .func = on_done });
}

fn releasePendingEvent(self: *ServiceWorkerGlobalScope) void {
    const event = self._pending_event orelse return;
    self._pending_event = null;
    event.releaseRef(self._proto.page);
}

fn setState(self: *ServiceWorkerGlobalScope, state: ServiceWorker.State) void {
    if (self._state == state or self._state == .redundant) {
        // redundant is terminal, once reached, we cannot put the worker back
        // into installed/activating
        return;
    }
    self._state = state;

    // Handles only *schedule* their statechange event, so this walk never
    // crosses into user JS and can't have the list mutated under it.
    var node = self._registrations.first;
    while (node) |n| : (node = n.next) {
        const registration: *ServiceWorkerRegistration = @alignCast(@fieldParentPtr("_node", n));
        registration.stateChanged();
    }
}

pub fn receiveMessage(self: *ServiceWorkerGlobalScope, data: js.Value) !void {
    if (self._state == .redundant) {
        return;
    }

    const cloned_data: ?js.Value.Global = blk: {
        var ls: js.Local.Scope = undefined;
        self._proto.js.localScope(&ls);
        defer ls.deinit();

        const cloned = data.structuredCloneTo(&ls.local) catch break :blk null;
        break :blk cloned.persist() catch break :blk null;
    };

    if (self._state == .parsed) {
        // script hasn't loaded yet
        try self._pending_messages.append(self._proto.arena, cloned_data);
        return;
    }

    try self.scheduleMessage(cloned_data);
}

fn scheduleMessage(self: *ServiceWorkerGlobalScope, cloned_data: ?js.Value.Global) !void {
    const wgs = self._proto;
    const session = wgs._session;

    const message_arena = try session.getArena(.tiny, "ServiceWorkerGlobalScope.receiveMessage");
    errdefer message_arena.release();

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .data = cloned_data,
        .worker_scope = self,
        .arena = message_arena,
    };

    try wgs.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "ServiceWorkerGlobalScope.receiveMessage",
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

fn drainPendingMessages(self: *ServiceWorkerGlobalScope) void {
    for (self._pending_messages.items) |cloned_data| {
        self.scheduleMessage(cloned_data) catch |err| {
            log.warn(.browser, "SWGS drain msg failed", .{ .err = err });
            if (cloned_data) |d| {
                d.release();
            }
        };
    }
    self._pending_messages.clearRetainingCapacity();
}

const ReceiveMessageCallback = struct {
    data: ?js.Value.Global,
    arena: *lp.Arena,
    worker_scope: *ServiceWorkerGlobalScope,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| {
            d.release();
        }
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.arena.release();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const wgs = self.worker_scope._proto;
        const target = wgs.asEventTarget();

        const data = self.data orelse {
            if (wgs._event_manager.hasDirectListeners(target, "messageerror", null)) {
                const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                    .bubbles = false,
                    .cancelable = false,
                }, wgs.page)).asEvent();
                try wgs.dispatch(target, event, null, .{});
            }
            return null;
        };

        const on_message = self.worker_scope._on_message;
        if (wgs._event_manager.hasDirectListeners(target, "message", on_message) == false) {
            data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.data.? },
            .bubbles = false,
            .cancelable = false,
        }, wgs.page)).asEvent();
        try wgs.dispatch(target, event, on_message, .{});
        return null;
    }
};

pub fn getRegistration(self: *ServiceWorkerGlobalScope, exec: *js.Execution) !*ServiceWorkerRegistration {
    if (self._self_registration) |r| {
        return r;
    }
    const r = try ServiceWorkerRegistration.init(self, null, exec);
    self._self_registration = r;
    return r;
}

pub fn getServiceWorker(self: *ServiceWorkerGlobalScope, exec: *js.Execution) !*ServiceWorker {
    const registration = try self.getRegistration(exec);
    return registration.worker(self);
}

// TODO: Need an `ExtendableCookieChangeEvent` so that we can fire change
// notifications (for now, reads work)
pub fn getCookieStore(self: *ServiceWorkerGlobalScope) !*CookieStore {
    if (self._cookie_store) |cs| {
        return cs;
    }
    const wgs = self._proto;
    const cs = try wgs._factory.eventTargetWithAllocator(wgs.arena, CookieStore{ ._proto = undefined });
    self._cookie_store = cs;
    return cs;
}

// We don't yet have anything that "waits", so we can resolve this immediately.
// Makes sure that the following common usage doesn't fail:
//    self.addEventListener('install', e => e.waitUntil(self.skipWaiting()))
pub fn skipWaiting(_: *ServiceWorkerGlobalScope, exec: *const js.Execution) !js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();
    resolver.resolve("ServiceWorkerGlobalScope.skipWaiting", {});
    return resolver.promise();
}

pub fn getOnInstall(self: *const ServiceWorkerGlobalScope) ?js.Function.Global {
    return self._on_install;
}

pub fn setOnInstall(self: *ServiceWorkerGlobalScope, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_install = WorkerGlobalScope.getFunctionFromSetter(setter);
}

pub fn getOnActivate(self: *const ServiceWorkerGlobalScope) ?js.Function.Global {
    return self._on_activate;
}

pub fn setOnActivate(self: *ServiceWorkerGlobalScope, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_activate = WorkerGlobalScope.getFunctionFromSetter(setter);
}

pub fn getOnMessage(self: *const ServiceWorkerGlobalScope) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *ServiceWorkerGlobalScope, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_message = WorkerGlobalScope.getFunctionFromSetter(setter);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ServiceWorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "ServiceWorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const registration = bridge.accessor(ServiceWorkerGlobalScope.getRegistration, null, .{});
    pub const serviceWorker = bridge.accessor(ServiceWorkerGlobalScope.getServiceWorker, null, .{});
    pub const skipWaiting = bridge.function(ServiceWorkerGlobalScope.skipWaiting, .{});
    pub const cookieStore = bridge.accessor(ServiceWorkerGlobalScope.getCookieStore, null, .{});

    pub const oninstall = bridge.accessor(ServiceWorkerGlobalScope.getOnInstall, ServiceWorkerGlobalScope.setOnInstall, .{});
    pub const onactivate = bridge.accessor(ServiceWorkerGlobalScope.getOnActivate, ServiceWorkerGlobalScope.setOnActivate, .{});
    pub const onmessage = bridge.accessor(ServiceWorkerGlobalScope.getOnMessage, ServiceWorkerGlobalScope.setOnMessage, .{});

    // Deliberately absent: `onfetch` and `clients`. Nothing dispatches fetch
    // events yet, and an accessor that silently never fires is worse than a
    // missing one — a site can at least feature-detect the latter.
};
