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

// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent
pub const MouseEvent = struct {
    pub const Self = parser.MouseEvent;
    pub const prototype = *Event;

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

    pub fn constructor(event_type: []const u8, opts_: ?MouseEventInit) !*Self {
        const opts = opts_ orelse MouseEventInit{};

        const mouse_event = try parser.mouseEventCreate();

        try parser.mouseEventInit(mouse_event, event_type, .{
            .x = opts.clientX,
            .y = opts.clientY,
            .ctrl = opts.ctrlKey,
            .shift = opts.shiftKey,
            .alt = opts.altKey,
            .meta = opts.metaKey,
            .button = opts.button,
        });

        return mouse_event;
    }

    // These is just an alias for clientX.
    pub fn get_x(self: *Self) !i32 {
        return self.cx;
    }

    // These is just an alias for clientY.
    pub fn get_y(self: *Self) !i32 {
        return self.cy;
    }

    pub fn get_clientX(self: *Self) !i32 {
        return self.cx;
    }

    pub fn get_clientY(self: *Self) !i32 {
        return self.cy;
    }

    pub fn get_screenX(self: *Self) !i32 {
        return self.sx;
    }

    pub fn get_screenY(self: *Self) !i32 {
        return self.sy;
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
        .{ "event.screenX", "0" },
        .{ "event.screenY", "0" },
        .{ "let new_event = new MouseEvent('click2', { 'clientX': 10, 'clientY': 20 })", "undefined" },
        .{ "new_event.x", "10" },
        .{ "new_event.y", "20" },
        .{ "new_event.screenX", "10" },
        .{ "new_event.screenY", "20" },
    }, .{});
}
