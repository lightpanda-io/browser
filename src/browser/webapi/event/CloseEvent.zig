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

const Frame = @import("../../Frame.zig");
const Event = @import("../Event.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const CloseEvent = @This();
_proto: *Event,
_code: u16 = 1000,
_reason: []const u8 = "",
_was_clean: bool = true,

const CloseEventOptions = struct {
    code: u16 = 1000,
    reason: []const u8 = "",
    wasClean: bool = true,
};

const Options = Event.inheritOptions(CloseEvent, CloseEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*CloseEvent {
    const arena = try frame.getArena(.tiny, "CloseEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*CloseEvent {
    const arena = try frame.getArena(.tiny, "CloseEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*CloseEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        CloseEvent{
            ._proto = undefined,
            ._code = opts.code,
            ._reason = if (opts.reason.len > 0) try arena.dupe(u8, opts.reason) else "",
            ._was_clean = opts.wasClean,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
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
    const js = @import("../../js/js.zig");
    pub const bridge = js.Bridge(CloseEvent);

    pub const Meta = struct {
        pub const name = "CloseEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(CloseEvent.init, .{});
    pub const code = bridge.accessor(CloseEvent.getCode, null, .{});
    pub const reason = bridge.accessor(CloseEvent.getReason, null, .{});
    pub const wasClean = bridge.accessor(CloseEvent.getWasClean, null, .{});
};
