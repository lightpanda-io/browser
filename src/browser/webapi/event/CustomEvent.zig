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

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const CustomEvent = @This();

_proto: *Event,
_detail: ?js.Object = null,
_arena: Allocator,

pub const InitOptions = struct {
    detail: ?js.Object = null,
    bubbles: bool = false,
    cancelable: bool = false,
};

pub fn init(typ: []const u8, opts_: ?InitOptions, page: *Page) !*CustomEvent {
    const arena = page.arena;
    const opts = opts_ orelse InitOptions{};

    const event = try page._factory.event(typ, CustomEvent{
        ._arena = arena,
        ._proto = undefined,
        ._detail = if (opts.detail) |detail| try detail.persist() else null,
    });

    event._proto._bubbles = opts.bubbles;
    event._proto._cancelable = opts.cancelable;

    return event;
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
};

const testing = @import("../../../testing.zig");
test "WebApi: CustomEvent" {
    try testing.htmlRunner("event/custom_event.html", .{});
}
