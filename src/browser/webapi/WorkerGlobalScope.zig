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
const JS = @import("../js/js.zig");

const log = @import("../../log.zig");

const Console = @import("Console.zig");
const Crypto = @import("Crypto.zig");
const EventTarget = @import("EventTarget.zig");
const Factory = @import("../Factory.zig");
const Performance = @import("Performance.zig");
const Session = @import("../Session.zig");
const Worker = @import("Worker.zig");

const Allocator = std.mem.Allocator;

const WorkerGlobalScope = @This();

// Meant to follow the same field naming as Page so that an anytype of generic
// can access these the same for a Page of a WGS.
// These fields represent the "Page"-like component of the WGS
_session: *Session,
_factory: *Factory,
_identity: JS.Identity = .{},
arena: Allocator,
call_arena: Allocator,
url: [:0]const u8,
buf: [1024]u8 = undefined, // same size as page.buf
js: *JS.Context,

// Reference back to the Worker object (for postMessage to page)
_worker: *Worker,

// These fields represent the "Window"-like component of the WGS
_proto: *EventTarget,
_console: Console = .init,
_crypto: Crypto = .init,
_performance: Performance,
_on_error: ?JS.Function.Global = null,
_on_rejection_handled: ?JS.Function.Global = null,
_on_unhandled_rejection: ?JS.Function.Global = null,
_on_message: ?JS.Function.Global = null,

pub fn init(worker: *Worker, url: [:0]const u8) !*WorkerGlobalScope {
    const arena = worker._arena;
    const session = worker._page._session;
    const factory = &session.factory;

    const call_arena = try session.getArena(.{ .debug = "WorkerGlobalScope.call_arena" });
    errdefer session.releaseArena(call_arena);

    const self = try factory.eventTargetWithAllocator(arena, WorkerGlobalScope{
        .url = url,
        .arena = arena,
        .js = undefined,
        .call_arena = call_arena,
        ._session = session,
        ._identity = .{},
        ._proto = undefined,
        ._factory = factory,
        ._worker = worker,
        ._performance = .init(),
    });
    errdefer factory.destroy(self);

    self.js = try session.browser.env.createWorkerContext(self, .{
        .call_arena = call_arena,
        .identity_arena = arena,
        .identity = &self._identity,
    });

    return self;
}

pub fn deinit(self: *WorkerGlobalScope) void {
    self._identity.deinit();
    const session = self._session;
    session.browser.env.destroyContext(self.js);
    session.releaseArena(self.call_arena);
}

pub fn base(self: *const WorkerGlobalScope) [:0]const u8 {
    return self.url;
}

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

pub fn getOnMessage(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
}

/// Posts a message from the worker back to the page.
/// The message is serialized via JSON and dispatched on the Worker object.
pub fn postMessage(self: *WorkerGlobalScope, message: JS.Value, exec: *JS.Execution) !void {
    const worker = self._worker;
    const page = worker._page;

    // Serialize message to JSON
    const json = try message.toJson(self.arena);

    // Create callback to deliver message to Worker
    const callback = try self.arena.create(PostMessageToPageCallback);
    callback.* = .{
        .worker = worker,
        .json = json,
    };

    try page.js.scheduler.add(callback, PostMessageToPageCallback.run, 0, .{
        .name = "WorkerGlobalScope.postMessage",
        .low_priority = false,
    });

    _ = exec;
}

const PostMessageToPageCallback = struct {
    worker: *Worker,
    json: []const u8,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageToPageCallback = @ptrCast(@alignCast(ctx));
        const worker = self.worker;

        const on_message = worker._on_message orelse return null;

        const page = worker._page;

        var ls: JS.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        // Deserialize the message in page context
        const data = ls.local.parseJSON(self.json) catch |err| {
            log.err(.browser, "page msg parse fail", .{ .err = err });
            return null;
        };

        // Call the onmessage handler with a simple object {data: value}
        // TODO: Create proper MessageEvent
        const message_obj = ls.local.newObject();
        _ = message_obj.set("data", data, .{}) catch |err| {
            log.err(.browser, "message data set fail", .{ .err = err });
            return null;
        };

        const func = on_message.local(&ls.local);
        _ = func.call(void, .{message_obj.toValue()}) catch |err| {
            log.err(.browser, "page onmessage fail", .{ .err = err });
        };

        return null;
    }
};

pub fn btoa(_: *const WorkerGlobalScope, input: []const u8, exec: *JS.Execution) ![]const u8 {
    const base64 = @import("encoding/base64.zig");
    return base64.encode(exec.call_arena, input);
}

pub fn atob(_: *const WorkerGlobalScope, input: []const u8, exec: *JS.Execution) ![]const u8 {
    const base64 = @import("encoding/base64.zig");
    return base64.decode(exec.call_arena, input);
}

pub fn structuredClone(_: *const WorkerGlobalScope, value: JS.Value) !JS.Value {
    return value.structuredClone();
}

// TODO: importScripts - needs script loading infrastructure
// TODO: location - needs WorkerLocation
// TODO: navigator - needs WorkerNavigator
// TODO: Timer functions - need scheduler integration

const FunctionSetter = union(enum) {
    func: JS.Function.Global,
    anything: JS.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?JS.Function.Global {
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
    pub const postMessage = bridge.function(WorkerGlobalScope.postMessage, .{});

    pub const onmessage = bridge.accessor(WorkerGlobalScope.getOnMessage, WorkerGlobalScope.setOnMessage, .{});

    // Return false since workers don't have secure-context-only APIs
    pub const isSecureContext = bridge.property(false, .{ .template = false });
};
