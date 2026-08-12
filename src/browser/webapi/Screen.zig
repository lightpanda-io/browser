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
const Frame = @import("../Frame.zig");
const EventTarget = @import("EventTarget.zig");

pub fn registerTypes() []const type {
    return &.{
        Screen,
        Orientation,
    };
}

const Screen = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_orientation: ?*Orientation = null,

pub fn asEventTarget(self: *Screen) *EventTarget {
    return self._proto;
}

pub fn getOrientation(self: *Screen, frame: *Frame) !*Orientation {
    if (self._orientation) |orientation| {
        return orientation;
    }
    const orientation = try Orientation.init(frame);
    self._orientation = orientation;
    return orientation;
}

pub fn getWidth(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().width;
}

pub fn getHeight(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().screenHeight();
}

// The area a window may occupy: the screen less the taskbar/dock. A maximized
// window fills it exactly, so this is also window.outerHeight.
pub fn getAvailHeight(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().outerHeight();
}

// The maximized window is flush left on every desktop we emulate; only the
// vertical inset varies. Chrome always exposes availLeft, so a missing property
// is itself a tell.
pub fn getAvailLeft(_: *const Screen, _: *Frame) u32 {
    return 0;
}

// System chrome above the window: the macOS menu bar or the GNOME top bar.
// Windows puts its taskbar at the bottom, so availTop stays 0 there. A macOS
// profile reporting availTop === 0 is the headless shape.
pub fn getAvailTop(_: *const Screen, frame: *Frame) u32 {
    return switch (frame._session.browser.app.config.fingerprint_profile.platform) {
        .macos => 25,
        .windows => 0,
        .linux => 27,
    };
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
    pub const availWidth = bridge.accessor(Screen.getWidth, null, .{});
    pub const availHeight = bridge.accessor(Screen.getAvailHeight, null, .{});
    pub const availLeft = bridge.accessor(Screen.getAvailLeft, null, .{});
    pub const availTop = bridge.accessor(Screen.getAvailTop, null, .{});
    pub const colorDepth = bridge.property(24, .{ .template = false });
    pub const pixelDepth = bridge.property(24, .{ .template = false });
    pub const orientation = bridge.accessor(Screen.getOrientation, null, .{});
};

pub const Orientation = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn init(frame: *Frame) !*Orientation {
        return frame._factory.eventTarget(Orientation{
            ._proto = undefined,
        });
    }

    pub fn asEventTarget(self: *Orientation) *EventTarget {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Orientation);

        pub const Meta = struct {
            pub const name = "ScreenOrientation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const angle = bridge.property(0, .{ .template = false });
        pub const @"type" = bridge.property("landscape-primary", .{ .template = false });
    };
};
