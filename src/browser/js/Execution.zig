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
const Factory = @import("../Factory.zig");
const HttpClient = @import("../HttpClient.zig");
const EventManagerBase = @import("../EventManagerBase.zig");

const Blob = @import("../webapi/Blob.zig");
const Event = @import("../webapi/Event.zig");
const EventTarget = @import("../webapi/EventTarget.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const Execution = @This();

context: *Context,

// Fields named to match Page for generic code (executor._factory works for both)
buf: []u8,
arena: Allocator,
call_arena: Allocator,
_factory: *Factory,
_scheduler: *Scheduler,

// Pointer to the url field (Page or WorkerGlobalScope) - allows access to current url even after navigation
url: *[:0]const u8,

// Pointer to the charset field of the global (Page or WorkerGlobalScope).
charset: *[]const u8,

// Returns the current base URL of the global scope.
pub fn base(self: *const Execution) [:0]const u8 {
    return self.context.global.base();
}

pub fn dupeString(self: *const Execution, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

pub fn getArena(self: *const Execution, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.context.page.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *const Execution, allocator: Allocator) void {
    self.context.page.releaseArena(allocator);
}

pub fn headersForRequest(self: *const Execution, headers: *HttpClient.Headers) !void {
    return switch (self.context.global) {
        inline else => |g| g.headersForRequest(headers),
    };
}

pub fn isSameOrigin(self: *const Execution, url: [:0]const u8) bool {
    return switch (self.context.global) {
        inline else => |g| g.isSameOrigin(url),
    };
}

pub fn lookupBlobUrl(self: *const Execution, url: []const u8) ?*Blob {
    return switch (self.context.global) {
        inline else => |g| g.lookupBlobUrl(url),
    };
}

pub fn dispatch(
    self: *const Execution,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    return switch (self.context.global) {
        inline else => |g| g.dispatch(target, event, handler, opts),
    };
}

pub fn hasDirectListeners(self: *const Execution, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return switch (self.context.global) {
        inline else => |g| g.hasDirectListeners(target, typ, handler),
    };
}

pub fn frameId(self: *const Execution) u32 {
    return switch (self.context.global) {
        inline else => |g| g._frame_id,
    };
}

pub fn loaderId(self: *const Execution) u32 {
    return switch (self.context.global) {
        inline else => |g| g._loader_id,
    };
}
