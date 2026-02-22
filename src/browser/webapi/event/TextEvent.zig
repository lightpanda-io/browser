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
const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const UIEvent = @import("UIEvent.zig");

const TextEvent = @This();

_proto: *UIEvent,
_data: []const u8 = "",

pub const TextEventOptions = struct {
    data: ?[]const u8 = null,
};

pub const Options = Event.inheritOptions(
    TextEvent,
    TextEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*TextEvent {
    const arena = try page.getArena(.{ .debug = "TextEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};

    const event = try page._factory.uiEvent(
        arena,
        type_string,
        TextEvent{
            ._proto = undefined,
            ._data = if (opts.data) |str| try arena.dupe(u8, str) else "",
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn deinit(self: *TextEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *TextEvent) *Event {
    return self._proto.asEvent();
}

pub fn getData(self: *const TextEvent) []const u8 {
    return self._data;
}

pub fn initTextEvent(
    self: *TextEvent,
    typ: []const u8,
    bubbles: bool,
    cancelable: bool,
    view: ?*@import("../Window.zig"),
    data: []const u8,
) !void {
    _ = view; // view parameter is ignored in modern implementations

    const event = self._proto._proto;
    if (event._event_phase != .none) {
        // Only allow initialization if event hasn't been dispatched
        return;
    }

    const arena = event._arena;
    event._type_string = try String.init(arena, typ, .{});
    event._bubbles = bubbles;
    event._cancelable = cancelable;
    self._data = try arena.dupe(u8, data);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEvent);

    pub const Meta = struct {
        pub const name = "TextEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(TextEvent.deinit);
    };

    // No constructor - TextEvent is created via document.createEvent('TextEvent')
    pub const data = bridge.accessor(TextEvent.getData, null, .{});
    pub const initTextEvent = bridge.function(TextEvent.initTextEvent, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEvent" {
    try testing.htmlRunner("event/text.html", .{});
}
