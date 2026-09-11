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

//! Execution context for worker-compatible APIs.
//!
//! This provides a common interface for APIs that work in both Window and Worker
//! contexts. Instead of taking `*Frame` (which is DOM-specific), these APIs take
//! `*Execution` which abstracts the common infrastructure.
//!
//! The bridge constructs an Execution on-the-fly from the current context,
//! whether it's a Page context or a Worker context.

const std = @import("std");
const lp = @import("lightpanda");

const Context = @import("Context.zig");
const Scheduler = @import("Scheduler.zig");
const Page = @import("../Page.zig");
const Session = @import("../Session.zig");
const Factory = @import("../Factory.zig");
const HttpClient = @import("../../network/HttpClient.zig");
const EventManagerBase = @import("../EventManagerBase.zig");

const Console = @import("../webapi/Console.zig");
const Cookie = @import("../webapi/storage/Cookie.zig");
const Event = @import("../webapi/Event.zig");
const EventTarget = @import("../webapi/EventTarget.zig");
const Performance = @import("../webapi/Performance.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const Execution = @This();

js: *Context,

// Fields named to match Page for generic code (executor._factory works for both)
buf: []u8,
arena: Allocator,
call_arena: Allocator,
local_arena: Allocator,

page: *Page,
session: *Session,
_factory: *Factory,
_scheduler: *Scheduler,

// Pointer to the url field (Page or WorkerGlobalScope) - allows access to current url even after navigation
url: *[:0]const u8,

// Pointer to the charset field of the global (Page or WorkerGlobalScope).
charset: *[]const u8,

pub fn dupeString(self: *const Execution, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

pub fn getArena(self: *const Execution, size_or_bucket: anytype, debug: []const u8) !*lp.Arena {
    return self.page.getArena(size_or_bucket, debug);
}

pub fn getPinnedArena(self: *const Execution, size_or_bucket: anytype, debug: []const u8) !*lp.Arena {
    return self.page.getPinnedArena(size_or_bucket, debug);
}

// Everything below forwards to the GlobalScope (Frame or WorkerGlobalScope);
// see global_scope.zig for what these actually do. They live on Execution too
// because the bridge hands callers an Execution, not a scope.
pub fn base(self: *const Execution) [:0]const u8 {
    return self.js.global.base();
}

pub fn headersForRequest(self: *const Execution, transfer: *HttpClient.Transfer) !void {
    return self.js.global.headersForRequest(transfer);
}

pub fn isSameOrigin(self: *const Execution, url: [:0]const u8) bool {
    return self.js.global.isSameOrigin(url);
}

pub fn makeRequest(self: *const Execution, req: HttpClient.Request) !void {
    return self.js.global.makeRequest(req);
}

pub fn newRequest(self: *const Execution, req: HttpClient.Request) !*HttpClient.Transfer {
    return self.js.global.newRequest(req);
}

pub fn getBroadcastChannels(self: *const Execution) *std.DoublyLinkedList {
    return self.js.global.getBroadcastChannels();
}

pub fn messagePorts(self: *const Execution) *std.DoublyLinkedList {
    return self.js.global.messagePorts();
}

pub fn origin(self: *const Execution) ?[]const u8 {
    return self.js.global.origin();
}

pub fn frameId(self: *const Execution) u32 {
    return self.js.global.frameId();
}

pub fn siteForCookies(self: *const Execution) Cookie.SiteForCookies {
    return self.js.global.siteForCookies();
}

pub fn httpOwner(self: *const Execution) *HttpClient.Owner {
    return self.js.global.httpOwner();
}

pub fn registerListener(
    self: *const Execution,
    target: *EventTarget,
    typ: []const u8,
    callback: EventManagerBase.Callback,
    opts: EventManagerBase.RegisterOptions,
) !void {
    return self.js.global.registerListener(target, typ, callback, opts);
}

pub fn removeListener(
    self: *const Execution,
    target: *EventTarget,
    typ: []const u8,
    callback: EventManagerBase.Callback,
    use_capture: bool,
) void {
    self.js.global.removeListener(target, typ, callback, use_capture);
}

pub fn dispatch(
    self: *const Execution,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    return self.js.global.dispatch(target, event, handler, opts);
}

pub fn hasDirectListeners(self: *const Execution, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self.js.global.hasDirectListeners(target, typ, handler);
}

pub fn performance(self: *const Execution) *Performance {
    return self.js.global.performance();
}

pub fn console(self: *const Execution) *Console {
    return self.js.global.console();
}
