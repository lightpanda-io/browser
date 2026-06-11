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
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const MouseEvent = @import("MouseEvent.zig");
const DataTransfer = @import("../DataTransfer.zig");

const String = lp.String;

const DragEvent = @This();

_proto: *MouseEvent,
_data_transfer: ?*DataTransfer,

pub const DragEventOptions = struct {
    dataTransfer: ?*DataTransfer = null,
};

pub const Options = Event.inheritOptions(DragEvent, DragEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*DragEvent {
    return initWithTrusted(typ, _opts, false, frame);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, frame: *Frame) !*DragEvent {
    return initWithTrusted(typ, _opts, true, frame);
}

fn initWithTrusted(typ: []const u8, _opts: ?Options, trusted: bool, frame: *Frame) !*DragEvent {
    const arena = try frame.getArena(.medium, "DragEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};

    const event = try frame._factory.mouseEvent(
        arena,
        type_string,
        MouseEvent{
            ._type = .{ .drag_event = undefined },
            ._proto = undefined,
            ._screen_x = opts.screenX,
            ._screen_y = opts.screenY,
            ._client_x = opts.clientX,
            ._client_y = opts.clientY,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._button = std.meta.intToEnum(MouseEvent.MouseButton, opts.button) catch return error.TypeError,
            ._buttons = opts.buttons,
            ._related_target = opts.relatedTarget,
        },
        DragEvent{
            ._proto = undefined,
            ._data_transfer = opts.dataTransfer,
        },
    );

    Event.populatePrototypes(event, opts, trusted);

    // Hold a ref on the DataTransfer so its arena outlives this event even if the
    // JS wrapper is collected first; released in deinit (mirrors MessageEvent's
    // Blob handling). The shared refcount lives on the Event base, so reach it
    // through asEvent() rather than the immediate _proto.
    if (opts.dataTransfer) |dt| {
        dt.acquireRef();
    }

    return event;
}

pub fn deinit(self: *DragEvent, page: *Page) void {
    if (self._data_transfer) |dt| {
        dt.releaseRef(page);
    }
    self.asEvent().deinit(page);
}

pub fn acquireRef(self: *DragEvent) void {
    self.asEvent().acquireRef();
}

pub fn releaseRef(self: *DragEvent, page: *Page) void {
    self.asEvent()._rc.release(self, page);
}

pub fn asEvent(self: *DragEvent) *Event {
    return self._proto.asEvent();
}

pub fn getDataTransfer(self: *const DragEvent) ?*DataTransfer {
    return self._data_transfer;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DragEvent);

    pub const Meta = struct {
        pub const name = "DragEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DragEvent.init, .{});
    pub const dataTransfer = bridge.accessor(DragEvent.getDataTransfer, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: DragEvent" {
    try testing.htmlRunner("event/drag.html", .{});
}
