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

// https://developer.mozilla.org/en-US/docs/Web/API/PageTransitionEvent
const PageTransitionEvent = @This();

_proto: *Event,
_persisted: bool,

const PageTransitionEventOptions = struct {
    persisted: ?bool = false,
};

const Options = Event.inheritOptions(PageTransitionEvent, PageTransitionEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*PageTransitionEvent {
    const arena = try page.getArena(.{ .debug = "PageTransitionEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, page);
}

pub fn initTrusted(typ: String, _opts: ?Options, page: *Page) !*PageTransitionEvent {
    const arena = try page.getArena(.{ .debug = "PageTransitionEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, page: *Page) !*PageTransitionEvent {
    const opts = _opts orelse Options{};

    const event = try page._factory.event(
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

pub fn deinit(self: *PageTransitionEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
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
        pub const weak = true;
        pub const finalizer = bridge.finalizer(PageTransitionEvent.deinit);
    };

    pub const constructor = bridge.constructor(PageTransitionEvent.init, .{});
    pub const persisted = bridge.accessor(PageTransitionEvent.getPersisted, null, .{});
};
