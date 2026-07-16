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
const Transfer = @import("../../network/HttpClient.zig").Transfer;

const Worker = @import("Worker.zig");
const MessagePort = @import("MessagePort.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");
const MessageEvent = @import("event/MessageEvent.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const SharedWorkerGlobalScope = @This();

_proto: *WorkerGlobalScope,
_arena: Allocator,

_url: [:0]const u8,
_name: []const u8,
_type: Worker.WorkerType,

// Key under which this scope is registered in session.shared_workers. Empty
// until registered; deinit/close use it to unregister.
_registry_key: []const u8 = "",

// used by HttpClient when generating notification
// Ultimately used by CDP to generate request/loader ids.
_frame_id: u32,
_loader_id: u32,

_closed: bool = false,
_script_loaded: bool = false,
_script_arena: ?Allocator = null,
_script_buffer: std.ArrayList(u8) = .empty,
_http_transfer: ?*Transfer = null,

_on_connect: ?js.Function.Global = null,

// Ports pending connnection, created before the initial script finished
_pending_connects: std.ArrayList(*MessagePort) = .empty,

pub fn init(frame: *Frame, url: [:0]const u8, name: []const u8, worker_type: Worker.WorkerType) !*SharedWorkerGlobalScope {
    const session = frame._session;

    const arena = try session.getArena(.small, "SharedWorker");
    errdefer session.releaseArena(arena);

    const owned_url = try arena.dupeZ(u8, url);
    const self = try arena.create(SharedWorkerGlobalScope);
    const proto = try WorkerGlobalScope.init(
        arena,
        owned_url,
        .{ .shared = self },
        worker_type == .module,
        session.nextFrameId(),
        session.nextLoaderId(),
        frame,
    );
    self.* = .{
        ._proto = proto,
        ._arena = arena,
        ._url = owned_url,
        ._name = try arena.dupe(u8, name),
        ._type = worker_type,
        ._frame_id = proto._frame_id,
        ._loader_id = proto._loader_id,
    };
    errdefer proto.deinit();

    if (!session.worker_loading_enabled) {
        log.debug(.browser, "shared worker disabled", .{ .url = owned_url });
        return self;
    }

    self._script_arena = try session.getArena(.large, "SharedWorker.script");
    errdefer self.releaseScriptArena();

    const transfer = proto.newRequest(.{
        .ctx = self,
        .method = .GET,
        .url = owned_url,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .resource_type = .script,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = owned_url,
        .notification = session.notification,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        log.err(.browser, "SharedWorker request", .{ .url = owned_url, .err = err });
        return err;
    };

    // Held for deinit's abort; the done, error and shutdown callbacks clear
    // it. The shutdown one matters: WorkerGlobalScope.deinit's abortOwner
    // kills the transfer, and deinit must not abort a freed transfer.
    self._http_transfer = transfer;

    transfer.submit() catch |err| {
        log.err(.browser, "SharedWorker request", .{ .url = owned_url, .err = err });
        return err;
    };
    return self;
}

// Called from Page.deinit of the owning (creating) page.
pub fn deinit(self: *SharedWorkerGlobalScope) void {
    if (self._http_transfer) |transfer| {
        transfer.abort(error.Abort);
        self._http_transfer = null;
    }
    self.releaseScriptArena();
    self.unregister();
    self._proto.deinit();
    self._proto._session.releaseArena(self._arena);
}

pub fn register(self: *SharedWorkerGlobalScope, lookup_key: []const u8) !void {
    // The key lives in our arena: every removal path (deinit, close) unregisters
    // before the arena is released.
    const key = try self._arena.dupe(u8, lookup_key);

    const session = self._proto._session;
    try session.shared_workers.put(session.arena, key, self);
    self._registry_key = key;
}

fn unregister(self: *SharedWorkerGlobalScope) void {
    if (self._registry_key.len == 0) {
        return;
    }
    _ = self._proto._session.shared_workers.remove(self._registry_key);
    self._registry_key = "";
}

// Establishes a new connection from a client context: creates the entangled
// port pair and queues the connect event. Returns the client's end.
pub fn connect(self: *SharedWorkerGlobalScope, client_exec: *js.Execution) !*MessagePort {
    const client_port = try MessagePort.init(client_exec);
    const worker_port = try MessagePort.init(&self._proto.js.execution);
    MessagePort.entangle(client_port, worker_port);

    if (self._script_loaded == false) {
        try self._pending_connects.append(self._arena, worker_port);
        return client_port;
    }

    try self.scheduleConnect(worker_port);
    return client_port;
}

pub fn getName(self: *const SharedWorkerGlobalScope) []const u8 {
    return self._name;
}

pub fn close(self: *SharedWorkerGlobalScope) void {
    // Once closed, new SharedWorker(url, name) must create a fresh instance.
    self.unregister();
    // TODO: we should also stop new tasks from being scheduled
    self._proto._session.idb.detachContext(self._proto.js);
    self._proto.js.scheduler.reset();
    self._closed = true;
}

pub fn getOnConnect(self: *const SharedWorkerGlobalScope) ?js.Function.Global {
    return self._on_connect;
}

pub fn setOnConnect(self: *SharedWorkerGlobalScope, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_connect = WorkerGlobalScope.getFunctionFromSetter(setter);
}

fn httpHeaderCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *SharedWorkerGlobalScope = @ptrCast(@alignCast(transfer.req.ctx));

    const status = transfer.responseStatus() orelse return .abort;
    if (status < 200 or status >= 300) {
        log.warn(.browser, "SharedWorker status", .{
            .url = self._url,
            .status = status,
        });
        return .abort;
    }

    if (transfer.getContentLength()) |cl| {
        try self._script_buffer.ensureTotalCapacity(self._script_arena.?, cl);
    }

    return .proceed;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *SharedWorkerGlobalScope = @ptrCast(@alignCast(transfer.req.ctx));
    try self._script_buffer.appendSlice(self._script_arena.?, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *SharedWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    defer self.releaseScriptArena();

    const url = self._url;
    const script = self._script_buffer.items;

    if (comptime IS_DEBUG) {
        log.info(.browser, "shared worker fetch done", .{
            .url = url,
            .len = script.len,
        });
    }

    try self.loadInitialScript(script);
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *SharedWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    self.releaseScriptArena();
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *SharedWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    self.releaseScriptArena();

    log.err(.browser, "shared worker fetch error", .{
        .url = self._url,
        .err = err,
    });

    // The worker will never load and onconnect will never be registered.
    // Drain the buffered connects so they get dispatched (and dropped at the
    // "no listener" check) rather than accumulating until teardown.
    self._script_loaded = true;
    self.drainPendingConnects();
}

fn loadInitialScript(self: *SharedWorkerGlobalScope, script: []const u8) !void {
    const js_context = self._proto.js;

    if (js_context.env.terminatePending()) {
        return;
    }

    // The flip-and-drain runs after eval (and the trailing runMacrotasks) —
    // by which point the outer script has had its only chance to register
    // onconnect. On eval-throw the defer still fires; the connect events get
    // scheduled and then drop at the "no listener" check.
    defer {
        self._script_loaded = true;
        self.drainPendingConnects();
    }

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    switch (self._type) {
        .classic => _ = ls.local.eval(script, self._url) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }

            const caught = try_catch.caughtOrError(self._script_arena.?, err);
            log.err(.browser, "shared worker script error", .{ .url = self._url, .caught = caught });
            return;
        },
        .module => js_context.module(false, &ls.local, script, self._url, true) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }

            const caught = try_catch.caughtOrError(self._script_arena.?, err);
            log.err(.browser, "shared worker module error", .{ .url = self._url, .caught = caught });
            return;
        },
    }

    ls.local.runMacrotasks();
}

// Idempotent: reached from the done, error and shutdown callbacks and from
// deinit (the abort there re-enters via the error callback).
fn releaseScriptArena(self: *SharedWorkerGlobalScope) void {
    const arena = self._script_arena orelse return;
    self._script_arena = null;
    self._script_buffer = .empty;
    self._proto._session.releaseArena(arena);
}

fn drainPendingConnects(self: *SharedWorkerGlobalScope) void {
    for (self._pending_connects.items) |port| {
        self.scheduleConnect(port) catch |err| {
            log.warn(.browser, "shared worker drain connect failed", .{ .err = err });
        };
    }
    self._pending_connects.clearRetainingCapacity();
}

fn scheduleConnect(self: *SharedWorkerGlobalScope, port: *MessagePort) !void {
    const wgs = self._proto;
    const session = wgs._session;

    const connect_arena = try session.getArena(.tiny, "SharedWorkerGlobalScope.connect");
    errdefer session.releaseArena(connect_arena);

    const callback = try connect_arena.create(ConnectCallback);
    callback.* = .{
        .port = port,
        .worker_scope = self,
        .arena = connect_arena,
    };

    try wgs.js.scheduler.add(callback, ConnectCallback.run, 0, .{
        .name = "SharedWorkerGlobalScope.connect",
        .low_priority = false,
        .finalizer = ConnectCallback.cancelled,
    });
}

const ConnectCallback = struct {
    port: *MessagePort,
    arena: Allocator,
    worker_scope: *SharedWorkerGlobalScope,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ConnectCallback = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn deinit(self: *ConnectCallback) void {
        self.worker_scope._proto._session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ConnectCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker_scope = self.worker_scope;
        const wgs = worker_scope._proto;
        const target = wgs.asEventTarget();

        const on_connect = worker_scope._on_connect;
        if (!wgs._event_manager.hasDirectListeners(target, "connect", on_connect)) {
            return null;
        }

        // Per spec the connect event's data is the empty string and the new
        // port is both the sole entry of `ports` and the `source`.
        const event = (try MessageEvent.initTrusted(comptime .wrap("connect"), .{
            .data = .{ .string = "" },
            .source = .{ .port = self.port },
            .ports = &.{self.port},
            .bubbles = false,
            .cancelable = false,
        }, wgs._page)).asEvent();

        try wgs.dispatch(target, event, on_connect, .{ .context = "SharedWorkerGlobalScope.connect" });
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(SharedWorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "SharedWorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(SharedWorkerGlobalScope.getName, null, .{});
    pub const close = bridge.function(SharedWorkerGlobalScope.close, .{});
    pub const onconnect = bridge.accessor(SharedWorkerGlobalScope.getOnConnect, SharedWorkerGlobalScope.setOnConnect, .{});
};
