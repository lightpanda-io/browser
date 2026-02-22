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
const Allocator = std.mem.Allocator;
const String = @import("../../../string.zig").String;
const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const UIEvent = @import("UIEvent.zig");

const FocusEvent = @This();

_proto: *UIEvent,
_related_target: ?*EventTarget = null,

pub const FocusEventOptions = struct {
    relatedTarget: ?*EventTarget = null,
};

pub const Options = Event.inheritOptions(
    FocusEvent,
    FocusEventOptions,
);

pub fn initTrusted(typ: String, _opts: ?Options, page: *Page) !*FocusEvent {
    const arena = try page.getArena(.{ .debug = "FocusEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, page);
}

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*FocusEvent {
    const arena = try page.getArena(.{ .debug = "FocusEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, page);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, page: *Page) !*FocusEvent {
    const opts = _opts orelse Options{};

    const event = try page._factory.uiEvent(
        arena,
        typ,
        FocusEvent{
            ._proto = undefined,
            ._related_target = opts.relatedTarget,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *FocusEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *FocusEvent) *Event {
    return self._proto.asEvent();
}

pub fn getRelatedTarget(self: *const FocusEvent) ?*EventTarget {
    return self._related_target;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FocusEvent);

    pub const Meta = struct {
        pub const name = "FocusEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(FocusEvent.deinit);
    };

    pub const constructor = bridge.constructor(FocusEvent.init, .{});
    pub const relatedTarget = bridge.accessor(FocusEvent.getRelatedTarget, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FocusEvent" {
    try testing.htmlRunner("event/focus.html", .{});
}
