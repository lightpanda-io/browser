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

const CustomEvent = @This();

_proto: *Event,
_detail: ?js.Value.Temp = null,
_arena: Allocator,

const CustomEventOptions = struct {
    detail: ?js.Value.Temp = null,
};

const Options = Event.inheritOptions(CustomEvent, CustomEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*CustomEvent {
    const arena = try page.getArena(.{ .debug = "CustomEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = opts_ orelse Options{};
    const event = try page._factory.event(
        arena,
        type_string,
        CustomEvent{
            ._arena = arena,
            ._proto = undefined,
            ._detail = opts.detail,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn initCustomEvent(
    self: *CustomEvent,
    event_string: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
    detail_: ?js.Value.Temp,
) !void {
    // This function can only be called after the constructor has called.
    // So we assume proto is initialized already by constructor.
    self._proto._type_string = try String.init(self._proto._arena, event_string, .{});
    self._proto._bubbles = bubbles orelse false;
    self._proto._cancelable = cancelable orelse false;
    // Detail is stored separately.
    self._detail = detail_;
}

pub fn deinit(self: *CustomEvent, shutdown: bool, page: *Page) void {
    if (self._detail) |d| {
        page.js.release(d);
    }
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *CustomEvent) *Event {
    return self._proto;
}

pub fn getDetail(self: *const CustomEvent) ?js.Value.Temp {
    return self._detail;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CustomEvent);

    pub const Meta = struct {
        pub const name = "CustomEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(CustomEvent.deinit);
        pub const enumerable = false;
    };

    pub const constructor = bridge.constructor(CustomEvent.init, .{});
    pub const detail = bridge.accessor(CustomEvent.getDetail, null, .{});
    pub const initCustomEvent = bridge.function(CustomEvent.initCustomEvent, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CustomEvent" {
    try testing.htmlRunner("event/custom_event.html", .{});
}
