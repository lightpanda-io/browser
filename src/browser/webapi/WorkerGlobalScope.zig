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

// The struct is like a mix of Page and Window, but a very limited Page and
// a very limited Window. This dual-purpose does make it a bit harder to know
// what's what...e.g what is a WebAPI call and what it called internally.

const std = @import("std");
const lp = @import("lightpanda");

const JS = @import("../js/js.zig");
const URL = @import("../URL.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");
const Factory = @import("../Factory.zig");
const Session = @import("../Session.zig");
const HttpClient = @import("../../network/HttpClient.zig");
const EventManagerBase = @import("../EventManagerBase.zig");
const ScriptManagerBase = @import("../ScriptManagerBase.zig");

const Event = @import("Event.zig");
const Crypto = @import("Crypto.zig");
const Console = @import("Console.zig");
const Navigator = @import("Navigator.zig");
const Timers = @import("Timers.zig");
const EventTarget = @import("EventTarget.zig");
const Performance = @import("Performance.zig");
const WorkerLocation = @import("WorkerLocation.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const Fetch = @import("net/Fetch.zig");
const idb = @import("storage/idb/idb.zig");
const CookieStore = @import("storage/CookieStore.zig");
const MessagePort = @import("MessagePort.zig");
const SharedWorkerGlobalScope = @import("SharedWorkerGlobalScope.zig");
const DedicatedWorkerGlobalScope = @import("DedicatedWorkerGlobalScope.zig");

const builtin = @import("builtin");
const IS_DEBUG = builtin.mode == .Debug;

const log = lp.log;
const Allocator = std.mem.Allocator;

const WorkerGlobalScope = @This();

_type: Type,
_frame: *Frame,
_is_module: bool,

// Meant to follow the same field naming as Page so that an anytype of generic
// can access these the same for a Page of a WGS.
// These fields represent the "Page"-like component of the WGS
_page: *Page,
_session: *Session,
_factory: *Factory,
_identity: JS.Identity = .{},
_http_owner: HttpClient.Owner,

arena: Allocator,
call_arena: Allocator,
local_arena: Allocator,
url: [:0]const u8,
// Same-origin constraint: a worker's origin is inherited from its parent frame.
origin: ?[]const u8 = null,
buf: [1024]u8 = undefined, // same size as frame.buf
// Document charset (matches Page.charset). Workers default to UTF-8.
charset: []const u8 = "UTF-8",
js: *JS.Context,

// HTTP attribution
_frame_id: u32,
_loader_id: u32,

// Event management for non-DOM targets in worker context
_event_manager: EventManagerBase,

// Handles module imports (static + dynamic). No parser integration since
// workers don't have <script> tags.
_script_manager: ScriptManagerBase,

// List of open BroadcastChannels, used to route  HTTP attribution. Mirrors Frame's fiage between same-named
// channels in this worker's origin
_broadcast_channels: std.DoublyLinkedList = .{},

// List of MessagePorts living in this worker's context.
_message_ports: std.DoublyLinkedList = .{},

// These fields represent the "Window"-like component of the WGS
_proto: *EventTarget,
_console: Console = .init,
_crypto: Crypto = .init,
_navigator: Navigator = .init,
_performance: Performance,
_idb_factory: ?*idb.IDBFactory = null,
_on_error: ?JS.Function.Global = null,
_on_rejection_handled: ?JS.Function.Global = null,
_on_unhandled_rejection: ?JS.Function.Global = null,
_cookie_store: ?*CookieStore = null,

_location: WorkerLocation,

_timers: Timers = .{},

pub const Type = union(enum) {
    shared: *SharedWorkerGlobalScope,
    dedicated: *DedicatedWorkerGlobalScope,
};

pub fn init(
    arena: Allocator,
    url: [:0]const u8,
    child: Type,
    is_module: bool,
    frame_id: u32,
    loader_id: u32,
    frame: *Frame,
) !*WorkerGlobalScope {
    const session = frame._session;

    const call_arena = try session.getArena(.small, "WorkerGlobalScope.call_arena");
    errdefer session.releaseArena(call_arena);

    const local_arena = try session.getArena(.small, "WorkerGlobalScope.local_arena");
    errdefer session.releaseArena(local_arena);

    const factory = frame._factory;
    const self = try factory.eventTargetWithAllocator(arena, WorkerGlobalScope{
        .url = url,
        .arena = arena,
        .origin = frame.origin,
        .js = undefined,
        .call_arena = call_arena,
        .local_arena = local_arena,
        ._frame = frame,
        ._page = frame._page,
        ._session = session,
        ._identity = .{},
        ._type = child,
        ._proto = undefined,
        ._factory = factory,
        ._is_module = is_module,
        ._frame_id = frame_id,
        ._loader_id = loader_id,
        ._event_manager = .init(arena),
        ._script_manager = undefined,
        ._location = .{ ._url = url },
        ._performance = .init(),
        ._http_owner = undefined,
    });

    self._http_owner = .init(&frame._page.blob_urls, &self.origin);

    self._script_manager = ScriptManagerBase.init(
        arena,
        &session.browser.http_client,
        .{ .worker = self },
    );

    self.js = try session.browser.env.createWorkerContext(self, .{
        .call_arena = call_arena,
        .local_arena = local_arena,
        .identity_arena = arena,
        .identity = &self._identity,
    });

    // A dedicated worker is in the same agent cluster and inherits its creator's
    // origin. Adopt the parent frame's origin (shared *Origin + v8 security
    // token) in place of the context's initial opaque one, so same-origin
    // features like BroadcastChannel can reach across the page/worker boundary.
    try self.js.setOrigin(self.origin);

    return self;
}

pub fn deinit(self: *WorkerGlobalScope) void {
    const page = self._page;
    const session = page.session;
    const browser = session.browser;

    browser.http_client.abortOwner(&self._http_owner);

    // Close this worker's MessagePorts before the context dies: this severs
    // entanglement with page-side ports (which may outlive us) and releases
    // any still-queued messages.
    while (self._message_ports.first) |node| {
        const port: *MessagePort = @alignCast(@fieldParentPtr("_node", node));
        port.close(); // removes from self._message_ports
    }

    self._identity.deinit();
    self._script_manager.deinit();

    page.revokeBlobUrlsFor(self._frame_id);
    browser.env.destroyContext(self.js);
    session.releaseArena(self.call_arena);
    session.releaseArena(self.local_arena);
}

pub fn base(self: *const WorkerGlobalScope) [:0]const u8 {
    return self.url;
}

pub fn asEventTarget(self: *WorkerGlobalScope) *EventTarget {
    return self._proto;
}

// Dispatch an event to listeners on the given target within this worker context.
pub fn dispatch(
    self: *WorkerGlobalScope,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    try self._event_manager.dispatchDirect(
        self.call_arena,
        self.js,
        target,
        event,
        handler,
        self._page,
        opts,
    );
}

pub fn hasDirectListeners(self: *WorkerGlobalScope, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self._event_manager.hasDirectListeners(target, typ, handler);
}

// Workers don't have their own Referer; per spec, dedicated worker requests
// use the parent document's URL. Delegate to the owning frame.
pub fn headersForRequest(self: *WorkerGlobalScope, headers: *HttpClient.Headers) !void {
    return self._frame.headersForRequest(headers);
}

pub fn isSameOrigin(self: *const WorkerGlobalScope, url: [:0]const u8) bool {
    const current_origin = self.origin orelse return false;

    if (!std.mem.startsWith(u8, url, current_origin)) {
        return false;
    }
    return std.mem.eql(u8, URL.getHost(url), URL.getHost(current_origin));
}

pub fn makeRequest(self: *WorkerGlobalScope, req: HttpClient.Request) !void {
    return self._session.browser.http_client.request(req, &self._http_owner);
}

// Two-phase variant; see HttpClient.newRequest for the ownership contract.
pub fn newRequest(self: *WorkerGlobalScope, req: HttpClient.Request) !*HttpClient.Transfer {
    return self._session.browser.http_client.newRequest(req, &self._http_owner);
}

pub fn getSelf(self: *WorkerGlobalScope) *WorkerGlobalScope {
    return self;
}

pub fn setSelf(self: *WorkerGlobalScope, value: JS.Value) void {
    self.replaceGlobalProperty(value, "self");
}

pub fn getConsole(self: *WorkerGlobalScope) *Console {
    return &self._console;
}

pub fn setConsole(self: *WorkerGlobalScope, value: JS.Value) void {
    self.replaceGlobalProperty(value, "console");
}

pub fn getCrypto(self: *WorkerGlobalScope) *Crypto {
    return &self._crypto;
}

pub fn getNavigator(self: *WorkerGlobalScope) *Navigator {
    return &self._navigator;
}

pub fn performance(self: *WorkerGlobalScope) *Performance {
    return &self._performance;
}

pub fn getLocation(self: *WorkerGlobalScope) *WorkerLocation {
    return &self._location;
}

pub fn getCookieStore(self: *WorkerGlobalScope) !*CookieStore {
    if (self._cookie_store) |cs| return cs;
    const cs = try self._factory.eventTargetWithAllocator(self.arena, CookieStore{ ._proto = undefined });
    self._cookie_store = cs;
    return cs;
}

pub fn getOnError(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

const base64 = @import("encoding/base64.zig");
pub fn btoa(_: *const WorkerGlobalScope, input: base64.BinInput, exec: *JS.Execution) ![]const u8 {
    return base64.encode(exec.call_arena, input);
}

pub fn atob(_: *const WorkerGlobalScope, input: base64.BinInput, exec: *JS.Execution) !JS.String.OneByte {
    const bytes = try base64.decode(exec.call_arena, input);
    return .{ .bytes = bytes };
}

pub fn structuredClone(_: *const WorkerGlobalScope, value: JS.Value) !JS.Value {
    return value.structuredClone();
}

pub fn unhandledPromiseRejection(self: *WorkerGlobalScope, no_handler: bool, rejection: JS.PromiseRejection) !void {
    if (comptime IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "worker",
            .value = rejection.reason(),
            .stack = rejection.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    const target = self.asEventTarget();
    if (self._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (rejection.reason()) |r| try r.persist() else null,
            .promise = try rejection.promise().persist(),
        }, self._page)).asEvent();
        try self.dispatch(target, event, attribute_callback, .{});
    }
}

pub fn importScripts(self: *WorkerGlobalScope, urls: []const [:0]const u8) !void {
    if (self._is_module) {
        // not allowed to be called when the worker type is module (scripts should
        // use actual imports).
        return error.TypeError;
    }

    const session = self._session;
    const arena = try session.getArena(.large, "importScript");
    defer session.releaseArena(arena);

    for (urls) |url| {
        defer session.arena_pool.resetRetain(arena);
        try self.importScript(arena, url);
    }
}

fn importScript(self: *WorkerGlobalScope, arena: Allocator, url: [:0]const u8) !void {
    const session = self._session;

    const resolved_url = try URL.resolve(arena, self.url, url, .{});

    const http_client = &session.browser.http_client;

    var headers = try http_client.newHeaders();
    try self.headersForRequest(&headers);

    const response = http_client.syncRequest(arena, .{
        .url = resolved_url,
        .method = .GET,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .headers = headers,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = self.url,
        .resource_type = .script,
        .notification = session.notification,
        .shutdown_callback = HttpClient.noopShutdown, // syncRequest installs its own
    }, &self._http_owner) catch |err| {
        log.warn(.http, "importScript", .{ .url = resolved_url, .err = err });
        return error.NetworkError;
    };

    if (response.status != 200) {
        log.warn(.http, "importScript", .{ .url = resolved_url, .status = response.status });
        return error.NetworkError;
    }

    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: JS.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = ls.local.eval(response.body.items, url) catch |err| {
        const caught = try_catch.caughtOrError(arena, err);
        log.err(.browser, "importScript", .{ .url = resolved_url, .caught = caught });
        return;
    };

    ls.local.runMacrotasks();
}

pub fn reportError(self: *WorkerGlobalScope, err: JS.Value) !void {
    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.persist(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, self._page);

    // Invoke onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
    if (self._on_error) |on_error| {
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        const local_func = ls.toLocal(on_error);
        const result = local_func.call(JS.Value, .{
            error_event._message,
            error_event._filename,
            error_event._line_number,
            error_event._column_number,
            err,
        }) catch null;

        // Per spec: returning true from onerror cancels the event
        if (result) |r| {
            prevent_default = r.isTrue();
        }
    }

    const event = error_event.asEvent();
    event._prevent_default = prevent_default;
    // Pass null as handler: onerror was already called above with 5 args.
    // We still dispatch so that addEventListener('error', ...) listeners fire.
    try self.dispatch(self.asEventTarget(), event, null, .{});

    if (comptime builtin.is_test == false) {
        if (!event._prevent_default) {
            log.warn(.js, "worker.reportError", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

pub fn fetch(_: *const WorkerGlobalScope, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const JS.Execution) !JS.Promise {
    return Fetch.init(input, options, exec);
}

pub fn queueMicrotask(self: *WorkerGlobalScope, cb: JS.Function) void {
    self.js.queueMicrotaskFunc(cb);
}

pub fn setTimeout(self: *WorkerGlobalScope, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []JS.Value.Global, exec: *JS.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .name = "worker.setTimeout",
    });
}

pub fn clearTimeout(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub fn setInterval(self: *WorkerGlobalScope, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []JS.Value.Global, exec: *JS.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .name = "worker.setInterval",
    });
}

pub fn clearInterval(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub fn getIndexedDB(self: *WorkerGlobalScope, exec: *JS.Execution) !*idb.IDBFactory {
    if (self._idb_factory) |f| {
        return f;
    }
    const f = try exec._factory.create(idb.IDBFactory{});
    self._idb_factory = f;
    return f;
}

// Some properties are readonly but [Replaceable]. They get assigned as own
// data properties on the underlying v8::object that represents the global (the
// WorkerGlobalScope)
fn replaceGlobalProperty(self: *WorkerGlobalScope, value: JS.Value, comptime name: []const u8) void {
    const global = self.js.globalObject(value.local);
    _ = global.defineOwnProperty(name, value, 0);
}

pub const FunctionSetter = union(enum) {
    func: JS.Function.Global,
    anything: JS.Value,
};

pub fn getFunctionFromSetter(setter_: ?FunctionSetter) ?JS.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = JS.Bridge(WorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "WorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const console = bridge.accessor(WorkerGlobalScope.getConsole, WorkerGlobalScope.setConsole, .{});
    pub const crypto = bridge.accessor(WorkerGlobalScope.getCrypto, null, .{});
    pub const navigator = bridge.accessor(WorkerGlobalScope.getNavigator, null, .{});
    pub const performance = bridge.accessor(struct {
        // Unnecessary, But, our WebAPI getters are ALWAYS `fn getPerformance()...`.
        // But for performance, we _need_ to have fn performance() *Performance to
        // have parity with frame. So rather than having method called `performance`
        // and one called `getPerformance`, we create this wrapper here.
        pub fn wrap(wgs: *WorkerGlobalScope) *Performance {
            return wgs.performance();
        }
    }.wrap, null, .{});
    pub const self = bridge.accessor(WorkerGlobalScope.getSelf, WorkerGlobalScope.setSelf, .{});
    pub const location = bridge.accessor(WorkerGlobalScope.getLocation, null, .{});
    pub const cookieStore = bridge.accessor(WorkerGlobalScope.getCookieStore, null, .{});
    pub const indexedDB = bridge.accessor(WorkerGlobalScope.getIndexedDB, null, .{});

    pub const onerror = bridge.accessor(WorkerGlobalScope.getOnError, WorkerGlobalScope.setOnError, .{});
    pub const onrejectionhandled = bridge.accessor(WorkerGlobalScope.getOnRejectionHandled, WorkerGlobalScope.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(WorkerGlobalScope.getOnUnhandledRejection, WorkerGlobalScope.setOnUnhandledRejection, .{});

    pub const btoa = bridge.function(WorkerGlobalScope.btoa, .{});
    pub const atob = bridge.function(WorkerGlobalScope.atob, .{});
    pub const structuredClone = bridge.function(WorkerGlobalScope.structuredClone, .{});
    pub const reportError = bridge.function(WorkerGlobalScope.reportError, .{});
    pub const fetch = bridge.function(WorkerGlobalScope.fetch, .{});
    pub const importScripts = bridge.function(WorkerGlobalScope.importScripts, .{});
    pub const queueMicrotask = bridge.function(WorkerGlobalScope.queueMicrotask, .{});
    pub const setTimeout = bridge.function(WorkerGlobalScope.setTimeout, .{});
    pub const clearTimeout = bridge.function(WorkerGlobalScope.clearTimeout, .{});
    pub const setInterval = bridge.function(WorkerGlobalScope.setInterval, .{});
    pub const clearInterval = bridge.function(WorkerGlobalScope.clearInterval, .{});

    // Return false since workers don't have secure-context-only APIs
    pub const isSecureContext = bridge.property(false, .{ .template = false });
};
