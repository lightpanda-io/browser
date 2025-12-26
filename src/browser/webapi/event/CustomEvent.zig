// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../../js/js.zig");
const String = @import("../../..//string.zig").String;

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const CustomEvent = @This();

_proto: *Event,
_detail: ?js.Object = null,
_arena: Allocator,

const CustomEventOptions = struct {
    detail: ?js.Object = null,
};

const Options = Event.inheritOptions(CustomEvent, CustomEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*CustomEvent {
    const arena = page.arena;
    const opts = opts_ orelse Options{};

    const event = try page._factory.event(
        typ,
        CustomEvent{
            ._arena = arena,
            ._proto = undefined,
            ._detail = if (opts.detail) |detail| try detail.persist() else null,
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
    detail_: ?js.Object,
    page: *Page,
) !void {
    // This function can only be called after the constructor has called.
    // So we assume proto is initialized already by constructor.
    self._proto._type_string = try String.init(page.arena, event_string, .{});
    self._proto._bubbles = bubbles orelse false;
    self._proto._cancelable = cancelable orelse false;
    // Detail is stored separately.
    if (detail_) |detail| {
        self._detail = try detail.persist();
    }
}

pub fn asEvent(self: *CustomEvent) *Event {
    return self._proto;
}

pub fn getDetail(self: *const CustomEvent) ?js.Object {
    return self._detail;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CustomEvent);

    pub const Meta = struct {
        pub const name = "CustomEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(CustomEvent.init, .{});
    pub const detail = bridge.accessor(CustomEvent.getDetail, null, .{});
    pub const initCustomEvent = bridge.function(CustomEvent.initCustomEvent, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CustomEvent" {
    try testing.htmlRunner("event/custom_event.html", .{});
}
