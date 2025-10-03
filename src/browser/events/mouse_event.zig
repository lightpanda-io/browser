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

const std = @import("std");
const log = @import("../../log.zig");

const parser = @import("../netsurf.zig");
const Event = @import("event.zig").Event;

// TODO: We currently don't have a UIEvent interface so we skip it in the prototype chain.
// https://developer.mozilla.org/en-US/docs/Web/API/UIEvent
const UIEvent = Event;

// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent
pub const MouseEvent = struct {
    pub const Self = parser.MouseEvent;
    pub const prototype = *UIEvent;

    const MouseButton = enum(u16) {
        main_button = 0,
        auxillary_button = 1,
        secondary_button = 2,
        fourth_button = 3,
        fifth_button = 4,
    };

    const MouseEventInit = struct {
        screenX: i32 = 0,
        screenY: i32 = 0,
        clientX: i32 = 0,
        clientY: i32 = 0,
        ctrlKey: bool = false,
        shiftKey: bool = false,
        altKey: bool = false,
        metaKey: bool = false,
        button: MouseButton = .main_button,
    };

    pub fn constructor(event_type: []const u8, opts_: ?MouseEventInit) !*parser.MouseEvent {
        const opts = opts_ orelse MouseEventInit{};

        const mouse_event = try parser.mouseEventCreate();
        parser.eventSetInternalType(@ptrCast(mouse_event), .mouse_event);

        try parser.mouseEventInit(mouse_event, event_type, .{
            .x = opts.clientX,
            .y = opts.clientY,
            .ctrl = opts.ctrlKey,
            .shift = opts.shiftKey,
            .alt = opts.altKey,
            .meta = opts.metaKey,
            .button = @intFromEnum(opts.button),
        });

        if (!std.mem.eql(u8, event_type, "click")) {
            log.warn(.browser, "unsupported mouse event", .{ .event = event_type });
        }

        return mouse_event;
    }

    pub fn get_button(self: *parser.MouseEvent) u16 {
        return self.button;
    }

    // These is just an alias for clientX.
    pub fn get_x(self: *parser.MouseEvent) i32 {
        return self.cx;
    }

    // These is just an alias for clientY.
    pub fn get_y(self: *parser.MouseEvent) i32 {
        return self.cy;
    }

    pub fn get_clientX(self: *parser.MouseEvent) i32 {
        return self.cx;
    }

    pub fn get_clientY(self: *parser.MouseEvent) i32 {
        return self.cy;
    }

    pub fn get_screenX(self: *parser.MouseEvent) i32 {
        return self.sx;
    }

    pub fn get_screenY(self: *parser.MouseEvent) i32 {
        return self.sy;
    }
};

const testing = @import("../../testing.zig");
test "Browser: Events.Mouse" {
    try testing.htmlRunner("events/mouse.html");
}
