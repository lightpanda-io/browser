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

const String = @import("../../../string.zig").String;
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const CloseEvent = @This();

_proto: *Event,
_code: u16 = 0,
_reason: []const u8 = "",
_was_clean: bool = false,

pub const CloseEventOptions = struct {
    code: u16 = 0,
    reason: ?[]const u8 = null,
    wasClean: bool = false,
};

const Options = Event.inheritOptions(CloseEvent, CloseEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*CloseEvent {
    const arena = try page.getArena(.{ .debug = "CloseEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, page);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*CloseEvent {
    const arena = try page.getArena(.{ .debug = "CloseEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, opts_, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, opts_: ?Options, trusted: bool, page: *Page) !*CloseEvent {
    const opts = opts_ orelse Options{};

    const event = try page._factory.event(
        arena,
        typ,
        CloseEvent{
            ._proto = undefined,
            ._code = opts.code,
            ._reason = if (opts.reason) |value| try arena.dupe(u8, value) else "",
            ._was_clean = opts.wasClean,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *CloseEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *CloseEvent) *Event {
    return self._proto;
}

pub fn getCode(self: *const CloseEvent) u16 {
    return self._code;
}

pub fn getReason(self: *const CloseEvent) []const u8 {
    return self._reason;
}

pub fn getWasClean(self: *const CloseEvent) bool {
    return self._was_clean;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CloseEvent);

    pub const Meta = struct {
        pub const name = "CloseEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(CloseEvent.deinit);
    };

    pub const constructor = bridge.constructor(CloseEvent.init, .{});
    pub const code = bridge.accessor(CloseEvent.getCode, null, .{});
    pub const reason = bridge.accessor(CloseEvent.getReason, null, .{});
    pub const wasClean = bridge.accessor(CloseEvent.getWasClean, null, .{});
};
