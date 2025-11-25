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

const js = @import("../js/js.zig");

const Screen = @This();
_pad: bool = false,

pub const init: Screen = .{};

/// Total width of the screen in pixels
pub fn getWidth(_: *const Screen) u32 {
    return 1920;
}

/// Total height of the screen in pixels
pub fn getHeight(_: *const Screen) u32 {
    return 1080;
}

/// Available width (excluding OS UI elements like taskbar)
pub fn getAvailWidth(_: *const Screen) u32 {
    return 1920;
}

/// Available height (excluding OS UI elements like taskbar)
pub fn getAvailHeight(_: *const Screen) u32 {
    return 1040; // 40px reserved for taskbar/dock
}

/// Color depth in bits per pixel
pub fn getColorDepth(_: *const Screen) u32 {
    return 24;
}

/// Pixel depth in bits per pixel (typically same as colorDepth)
pub fn getPixelDepth(_: *const Screen) u32 {
    return 24;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Screen);

    pub const Meta = struct {
        pub const name = "Screen";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    // Read-only properties
    pub const width = bridge.accessor(Screen.getWidth, null, .{});
    pub const height = bridge.accessor(Screen.getHeight, null, .{});
    pub const availWidth = bridge.accessor(Screen.getAvailWidth, null, .{});
    pub const availHeight = bridge.accessor(Screen.getAvailHeight, null, .{});
    pub const colorDepth = bridge.accessor(Screen.getColorDepth, null, .{});
    pub const pixelDepth = bridge.accessor(Screen.getPixelDepth, null, .{});
};
