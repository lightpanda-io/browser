// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const parser = @import("../netsurf.zig");
const Event = @import("event.zig").Event;
const JsObject = @import("../env.zig").JsObject;

const InnerMouseEvent = @import("../netsurf.zig").MouseEvent;

// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent
pub const MouseEvent = struct {
    pub const prototype = *Event;

    proto: parser.Event,
    mouse_event: InnerMouseEvent,

    screenX: i32 = 0,
    screenY: i32 = 0,
    clientX: i32 = 0,
    clientY: i32 = 0,
    ctrlKey: bool = false,
    shiftKey: bool = false,
    altKey: bool = false,
    metaKey: bool = false,
    button: u16 = 0,

    const MouseEventInit = struct {
        screenX: i32 = 0,
        screenY: i32 = 0,
        clientX: i32 = 0,
        clientY: i32 = 0,
        ctrlKey: bool = false,
        shiftKey: bool = false,
        altKey: bool = false,
        metaKey: bool = false,
        button: u16 = 0,
    };

    pub fn constructor(event_type: []const u8, opts_: ?MouseEventInit) !MouseEvent {
        const opts = opts_ orelse MouseEventInit{};

        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, event_type, .{});
        try parser.eventSetInternalType(event, .mouse_event);

        // const mouse_event = try parser.mouseEventCreate();
        // defer parser.mouseEventDestroy(mouse_event);

        // try parser.mouseEventInit(mouse_event, event_type, .{
        //     .x = opts.clientX,
        //     .y = opts.clientY,
        //     .ctrl = opts.ctrl_key,
        //     .shift = opts.shift_key,
        //     .alt = opts.alt_key,
        //     .meta = opts.meta_key,
        //     .button = opts.button,
        // });

        return .{
            .proto = event.*,
            .mouse_event = undefined,
            .screenX = opts.screenX,
            .screenY = opts.screenY,
            .clientX = opts.clientX,
            .clientY = opts.clientY,
            .ctrlKey = opts.ctrlKey,
            .shiftKey = opts.shiftKey,
            .altKey = opts.altKey,
            .metaKey = opts.metaKey,
            .button = opts.button,
        };
    }

    // These is just an alias for clientX.
    pub fn get_x(self: *MouseEvent) !i32 {
        return self.clientX;
    }

    // These is just an alias for clientY.
    pub fn get_y(self: *MouseEvent) !i32 {
        return self.clientY;
    }

    pub fn get_clientX(self: *MouseEvent) !i32 {
        return self.clientX;
    }

    pub fn get_clientY(self: *MouseEvent) !i32 {
        return self.clientY;
    }
};

const testing = @import("../../testing.zig");
test "Browser.MouseEvent" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let event = new MouseEvent('click')", "undefined" },
        .{ "event.type", "click" },
        .{ "event instanceof MouseEvent", "true" },
        .{ "event instanceof Event", "true" },
        .{ "event.clientX", "0" },
        .{ "event.clientY", "0" },
        .{ "let new_event = new MouseEvent('click2', { 'clientX': 10, 'clientY': 20 })", "undefined" },
        .{ "new_event.x", "10" },
        .{ "new_event.y", "20" },
    }, .{});
}
