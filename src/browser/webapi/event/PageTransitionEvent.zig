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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

// https://developer.mozilla.org/en-US/docs/Web/API/PageTransitionEvent
const PageTransitionEvent = @This();

_proto: *Event,
_persisted: bool,

const PageTransitionEventOptions = struct {
    persisted: ?bool = false,
};

const Options = Event.inheritOptions(PageTransitionEvent, PageTransitionEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*PageTransitionEvent {
    const arena = try frame.getArena(.tiny, "PageTransitionEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*PageTransitionEvent {
    const arena = try frame.getArena(.tiny, "PageTransitionEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*PageTransitionEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        PageTransitionEvent{
            ._proto = undefined,
            ._persisted = opts.persisted orelse false,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *PageTransitionEvent) *Event {
    return self._proto;
}

pub fn getPersisted(self: *PageTransitionEvent) bool {
    return self._persisted;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PageTransitionEvent);

    pub const Meta = struct {
        pub const name = "PageTransitionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PageTransitionEvent.init, .{});
    pub const persisted = bridge.accessor(PageTransitionEvent.getPersisted, null, .{});
};
