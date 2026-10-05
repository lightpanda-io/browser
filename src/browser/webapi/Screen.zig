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

const lp = @import("lightpanda");

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

fn getOrientation(self: *Screen, frame: *Frame) !*Orientation {
    if (self._orientation) |orientation| {
        return orientation;
    }
    const orientation = try Orientation.init(frame);
    self._orientation = orientation;
    return orientation;
}

pub fn getWidth(_: *const Screen, frame: *Frame) u32 {
    const viewport = frame.page.getViewport();
    return viewport.screen_width orelse viewport.width;
}

pub fn getHeight(_: *const Screen, frame: *Frame) u32 {
    const viewport = frame.page.getViewport();
    return viewport.screen_height orelse viewport.height;
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
    pub const availHeight = bridge.property(1040, .{ .template = false });
    pub const colorDepth = bridge.property(24, .{ .template = false });
    pub const pixelDepth = bridge.property(24, .{ .template = false });
    pub const orientation = bridge.accessor(Screen.getOrientation, null, .{});
};

pub const Orientation = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _on_change: ?js.Function.Global = null,

    pub fn init(frame: *Frame) !*Orientation {
        return frame._factory.eventTarget(Orientation{
            ._proto = undefined,
        });
    }

    pub fn asEventTarget(self: *Orientation) *EventTarget {
        return self._proto;
    }

    pub fn inlineHandler(self: *const Orientation, typ: lp.String) ?js.Function.Global {
        if (typ.eql(comptime .wrap("change"))) {
            return self._on_change;
        }
        return null;
    }

    const LockType = enum {
        any,
        natural,
        landscape,
        portrait,
        @"portrait-primary",
        @"portrait-secondary",
        @"landscape-primary",
        @"landscape-secondary",
        pub const js_enum_from_string = true;
    };

    fn getAngle(_: *const Orientation, frame: *Frame) u16 {
        const orientation = frame.page.getViewport().orientation orelse return 0;
        return orientation.angle;
    }

    // Without an emulated orientation, the screen never rotates, so its
    // orientation follows its dimensions.
    fn getType(_: *const Orientation, frame: *Frame) []const u8 {
        const viewport = frame.page.getViewport();
        if (viewport.orientation) |orientation| {
            return @tagName(orientation.type);
        }
        const width = viewport.screen_width orelse viewport.width;
        const height = viewport.screen_height orelse viewport.height;
        return if (height > width) "portrait-primary" else "landscape-primary";
    }

    fn lock(_: *Orientation, _: LockType) !js.Promise {
        return error.NotSupported;
    }

    // Nothing is ever locked.
    fn unlock(_: *Orientation) void {}

    fn getOnChange(self: *const Orientation) ?js.Function.Global {
        return self._on_change;
    }

    fn setOnChange(self: *Orientation, cb: ?js.Function.Global) void {
        self._on_change = cb;
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
        pub const lock = bridge.function(Orientation.lock, .{});
        pub const unlock = bridge.function(Orientation.unlock, .{});
        pub const onchange = bridge.accessor(Orientation.getOnChange, Orientation.setOnChange, .{});
    };
};
