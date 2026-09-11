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

const HttpClient = @import("../network/HttpClient.zig");

const Event = @import("webapi/Event.zig");
const Console = @import("webapi/Console.zig");
const Cookie = @import("webapi/storage/Cookie.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const Performance = @import("webapi/Performance.zig");
const WorkerGlobalScope = @import("webapi/WorkerGlobalScope.zig");

const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const EventManagerBase = @import("EventManagerBase.zig");

pub const GlobalScope = union(enum) {
    frame: *Frame,
    worker: *WorkerGlobalScope,

    // Returns the current base URL of the global scope.
    pub fn base(self: GlobalScope) [:0]const u8 {
        return switch (self) {
            inline else => |g| g.base(),
        };
    }

    // The context currently entered for this global. Caller swaps it for the
    // duration of a call, so this is the running realm, not the main world.
    pub fn getJs(self: GlobalScope) *lp.js.Context {
        return switch (self) {
            inline else => |g| g.js,
        };
    }

    pub fn setJs(self: GlobalScope, ctx: *lp.js.Context) void {
        switch (self) {
            inline else => |g| g.js = ctx,
        }
    }

    pub fn session(self: GlobalScope) *Session {
        return switch (self) {
            inline else => |g| g._session,
        };
    }

    pub fn url(self: GlobalScope) [:0]const u8 {
        return switch (self) {
            inline else => |g| g.url,
        };
    }

    // The global's serialized origin (e.g. "https://example.com"), or null for
    // an opaque origin.
    pub fn origin(self: GlobalScope) ?[]const u8 {
        return switch (self) {
            inline else => |g| g.origin,
        };
    }

    pub fn frameId(self: GlobalScope) u32 {
        return switch (self) {
            inline else => |g| g._frame_id,
        };
    }

    pub fn headersForRequest(self: GlobalScope, transfer: *HttpClient.Transfer) !void {
        return switch (self) {
            inline else => |g| g.headersForRequest(transfer),
        };
    }

    pub fn isSameOrigin(self: GlobalScope, target: [:0]const u8) bool {
        return switch (self) {
            inline else => |g| g.isSameOrigin(target),
        };
    }

    pub fn makeRequest(self: GlobalScope, req: HttpClient.Request) !void {
        return switch (self) {
            inline else => |g| g.makeRequest(req),
        };
    }

    // Two-phase variant; see HttpClient.newRequest for the ownership contract.
    pub fn newRequest(self: GlobalScope, req: HttpClient.Request) !*HttpClient.Transfer {
        return switch (self) {
            inline else => |g| g.newRequest(req),
        };
    }

    pub fn getBroadcastChannels(self: GlobalScope) *std.DoublyLinkedList {
        return switch (self) {
            inline else => |g| &g._broadcast_channels,
        };
    }

    // The owning global's (Frame or WGS) list of live MessagePorts, walked at
    // that global's teardown to sever cross-context entanglement.
    pub fn messagePorts(self: GlobalScope) *std.DoublyLinkedList {
        return switch (self) {
            inline else => |g| &g._message_ports,
        };
    }

    pub fn siteForCookies(self: GlobalScope) Cookie.SiteForCookies {
        return self.httpOwner().siteForCookies();
    }

    // HttpClient.Owner of the current global (Frame or WGS). Used by code
    // that needs to register an in-flight network operation against the
    // owning scope without caring whether it's a Frame or a Worker — e.g.
    // WebSocket.init appending to `.websockets`.
    pub fn httpOwner(self: GlobalScope) *HttpClient.Owner {
        return switch (self) {
            inline else => |g| &g._http_owner,
        };
    }

    pub fn registerListener(
        self: GlobalScope,
        target: *EventTarget,
        typ: []const u8,
        callback: EventManagerBase.Callback,
        opts: EventManagerBase.RegisterOptions,
    ) !void {
        switch (self) {
            inline else => |g| _ = try g._event_manager.register(target, typ, callback, opts),
        }
    }

    pub fn removeListener(
        self: GlobalScope,
        target: *EventTarget,
        typ: []const u8,
        callback: EventManagerBase.Callback,
        use_capture: bool,
    ) void {
        switch (self) {
            inline else => |g| g._event_manager.remove(target, typ, callback, use_capture),
        }
    }

    pub fn dispatch(
        self: GlobalScope,
        target: *EventTarget,
        event: *Event,
        handler: anytype,
        comptime opts: EventManagerBase.DispatchDirectOptions,
    ) !void {
        return switch (self) {
            inline else => |g| g.dispatch(target, event, handler, opts),
        };
    }

    pub fn hasDirectListeners(self: GlobalScope, target: *EventTarget, typ: []const u8, handler: anytype) bool {
        return switch (self) {
            inline else => |g| g.hasDirectListeners(target, typ, handler),
        };
    }

    pub fn performance(self: GlobalScope) *Performance {
        return switch (self) {
            inline else => |g| g.performance(),
        };
    }

    pub fn console(self: GlobalScope) *Console {
        return switch (self) {
            .frame => |frame| frame.window.getConsole(),
            .worker => |worker| worker.getConsole(),
        };
    }
};
