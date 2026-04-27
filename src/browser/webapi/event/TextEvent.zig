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
const UIEvent = @import("UIEvent.zig");

const String = lp.String;

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

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*TextEvent {
    const arena = try frame.getArena(.tiny, "TextEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};

    const event = try frame._factory.uiEvent(
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

pub fn asEvent(self: *TextEvent) *Event {
    return self._proto.asEvent();
}

pub fn getData(self: *const TextEvent) []const u8 {
    return self._data;
}

pub fn initTextEvent(
    self: *TextEvent,
    typ: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
    view: ?*@import("../Window.zig"),
    data: ?[]const u8,
) !void {
    const ui = self._proto;
    const event = ui._proto;
    if (event._event_phase != .none) {
        return;
    }

    const arena = event._arena;
    event._type_string = try String.init(arena, typ, .{});
    event._bubbles = bubbles orelse false;
    event._cancelable = cancelable orelse false;
    ui._view = view;
    self._data = if (data) |d| try arena.dupe(u8, d) else "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEvent);

    pub const Meta = struct {
        pub const name = "TextEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // No constructor - TextEvent is created via document.createEvent('TextEvent')
    pub const data = bridge.accessor(TextEvent.getData, null, .{});
    pub const initTextEvent = bridge.function(TextEvent.initTextEvent, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEvent" {
    try testing.htmlRunner("event/text.html", .{});
}
