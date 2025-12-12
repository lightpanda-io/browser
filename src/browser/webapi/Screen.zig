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
const Page = @import("../Page.zig");
const EventTarget = @import("EventTarget.zig");

pub fn registerTypes() []const type {
    return &.{
        Screen,
        Orientation,
    };
}

const Screen = @This();

_proto: *EventTarget,
_orientation: ?*Orientation = null,

pub fn init(page: *Page) !*Screen {
    return page._factory.eventTarget(Screen{
        ._proto = undefined,
        ._orientation = null,
    });
}

pub fn asEventTarget(self: *Screen) *EventTarget {
    return self._proto;
}

pub fn getWidth(_: *const Screen) u32 {
    return 1920;
}

pub fn getHeight(_: *const Screen) u32 {
    return 1080;
}

pub fn getAvailWidth(_: *const Screen) u32 {
    return 1920;
}

pub fn getAvailHeight(_: *const Screen) u32 {
    return 1040; // 40px reserved for taskbar/dock
}

pub fn getColorDepth(_: *const Screen) u32 {
    return 24;
}

pub fn getPixelDepth(_: *const Screen) u32 {
    return 24;
}

pub fn getOrientation(self: *Screen, page: *Page) !*Orientation {
    if (self._orientation) |orientation| {
        return orientation;
    }
    const orientation = try Orientation.init(page);
    self._orientation = orientation;
    return orientation;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Screen);

    pub const Meta = struct {
        pub const name = "Screen";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(Screen.getWidth, null, .{});
    pub const height = bridge.accessor(Screen.getHeight, null, .{});
    pub const availWidth = bridge.accessor(Screen.getAvailWidth, null, .{});
    pub const availHeight = bridge.accessor(Screen.getAvailHeight, null, .{});
    pub const colorDepth = bridge.accessor(Screen.getColorDepth, null, .{});
    pub const pixelDepth = bridge.accessor(Screen.getPixelDepth, null, .{});
    pub const orientation = bridge.accessor(Screen.getOrientation, null, .{});
};

pub const Orientation = struct {
    _proto: *EventTarget,

    pub fn init(page: *Page) !*Orientation {
        return page._factory.eventTarget(Orientation{
            ._proto = undefined,
        });
    }

    pub fn asEventTarget(self: *Orientation) *EventTarget {
        return self._proto;
    }

    pub fn getAngle(_: *const Orientation) u32 {
        return 0;
    }

    pub fn getType(_: *const Orientation) []const u8 {
        return "landscape-primary";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Orientation);

        pub const Meta = struct {
            pub const name = "ScreenOrientation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const angle = bridge.accessor(Orientation.getAngle, null, .{});
        pub const @"type" = bridge.accessor(Orientation.getType, null, .{});
    };
};
