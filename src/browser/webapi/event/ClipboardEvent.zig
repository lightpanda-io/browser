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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const DataTransfer = @import("../DataTransfer.zig");

const String = lp.String;

/// https://w3c.github.io/clipboard-apis/#clipboard-event-interfaces
const ClipboardEvent = @This();

pub const Proto = Event;

_proto: *Event,
_clipboard_data: ?*DataTransfer,

const ClipboardEventOptions = struct {
    clipboardData: ?*DataTransfer = null,
};

const Options = Event.inheritOptions(ClipboardEvent, ClipboardEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*ClipboardEvent {
    const arena = try frame.getArena(.tiny, "ClipboardEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = opts_ orelse Options{};

    const event = try frame._factory.event(
        arena,
        type_string,
        ClipboardEvent{
            ._proto = undefined,
            ._clipboard_data = opts.clipboardData,
        },
    );

    Event.populatePrototypes(event, opts, false);

    // Hold a ref on the DataTransfer so its arena outlives this event even if
    // the JS wrapper is collected first; released in deinit (same as DragEvent).
    if (opts.clipboardData) |dt| {
        dt.acquireRef();
    }

    return event;
}

pub fn deinit(self: *ClipboardEvent, page: *Page) void {
    if (self._clipboard_data) |dt| {
        dt.releaseRef(page);
    }
}

pub fn asEvent(self: *ClipboardEvent) *Event {
    return self._proto;
}

fn getClipboardData(self: *const ClipboardEvent) ?*DataTransfer {
    return self._clipboard_data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ClipboardEvent);

    pub const Meta = struct {
        pub const name = "ClipboardEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ClipboardEvent.init, .{});
    pub const clipboardData = bridge.accessor(ClipboardEvent.getClipboardData, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: ClipboardEvent" {
    try testing.htmlRunner("event/clipboard.html", .{});
}
