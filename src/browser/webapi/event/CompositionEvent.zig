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
const String = @import("../../../string.zig").String;

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const Allocator = std.mem.Allocator;

const CompositionEvent = @This();

_proto: *Event,
_data: []const u8 = "",

const CompositionEventOptions = struct {
    data: ?[]const u8 = null,
};

const Options = Event.inheritOptions(CompositionEvent, CompositionEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*CompositionEvent {
    const arena = try page.getArena(.{ .debug = "CompositionEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = opts_ orelse Options{};
    const event = try page._factory.event(
        arena,
        type_string,
        CompositionEvent{
            ._proto = undefined,
            ._data = if (opts.data) |str| try arena.dupe(u8, str) else "",
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn deinit(self: *CompositionEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *CompositionEvent) *Event {
    return self._proto;
}

pub fn getData(self: *const CompositionEvent) []const u8 {
    return self._data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CompositionEvent);

    pub const Meta = struct {
        pub const name = "CompositionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(CompositionEvent.deinit);
    };

    pub const constructor = bridge.constructor(CompositionEvent.init, .{});
    pub const data = bridge.accessor(CompositionEvent.getData, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CompositionEvent" {
    try testing.htmlRunner("event/composition.html", .{});
}
