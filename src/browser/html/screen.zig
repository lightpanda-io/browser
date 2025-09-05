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

const parser = @import("../netsurf.zig");
const EventTarget = @import("../dom/event_target.zig").EventTarget;

pub const Interfaces = .{
    Screen,
    ScreenOrientation,
};

// https://developer.mozilla.org/en-US/docs/Web/API/Screen
pub const Screen = struct {
    pub const prototype = *EventTarget;

    proto: parser.EventTargetTBase = .{ .internal_target_type = .screen },

    height: u32 = 1080,
    width: u32 = 1920,
    // https://developer.mozilla.org/en-US/docs/Web/API/Screen/colorDepth
    color_depth: u32 = 8,
    // https://developer.mozilla.org/en-US/docs/Web/API/Screen/pixelDepth
    pixel_depth: u32 = 8,
    orientation: ScreenOrientation = .{ .type = .landscape_primary },

    pub fn get_availHeight(self: *const Screen) u32 {
        return self.height;
    }

    pub fn get_availWidth(self: *const Screen) u32 {
        return self.width;
    }

    pub fn get_height(self: *const Screen) u32 {
        return self.height;
    }

    pub fn get_width(self: *const Screen) u32 {
        return self.width;
    }

    pub fn get_pixelDepth(self: *const Screen) u32 {
        return self.pixel_depth;
    }

    pub fn get_orientation(self: *const Screen) ScreenOrientation {
        return self.orientation;
    }
};

const ScreenOrientationType = enum {
    portrait_primary,
    portrait_secondary,
    landscape_primary,
    landscape_secondary,

    pub fn toString(self: ScreenOrientationType) []const u8 {
        return switch (self) {
            .portrait_primary => "portrait-primary",
            .portrait_secondary => "portrait-secondary",
            .landscape_primary => "landscape-primary",
            .landscape_secondary => "landscape-secondary",
        };
    }
};

pub const ScreenOrientation = struct {
    pub const prototype = *EventTarget;

    angle: u32 = 0,
    type: ScreenOrientationType,
    proto: parser.EventTargetTBase = .{ .internal_target_type = .screen_orientation },

    pub fn get_angle(self: *const ScreenOrientation) u32 {
        return self.angle;
    }

    pub fn get_type(self: *const ScreenOrientation) []const u8 {
        return self.type.toString();
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.Screen" {
    try testing.htmlRunner("html/screen.html");
}
