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
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");

// https://w3c.github.io/touch-events/#idl-def-touch
//
// Shared by any number of events (trusted or built by the page), so it's
// reference counted: its JS wrapper and each TouchEvent list it's in hold a ref.
const Touch = @This();

_rc: lp.RC = .{},
// EventTarget, not Element, per spec, and because dispatch retargets a trusted
// touch's target across shadow boundaries the same way it retargets
// Event.target (see TouchEvent.touchTargetPtr / EventManager's AdjustedTargets).
_target: ?*EventTarget,
_point: Point,
_page_x: f64,
_page_y: f64,
_screen_x: f64,
_screen_y: f64,

pub const Point = struct {
    x: f64,
    y: f64,
    id: i32 = 0,
    radiusX: f64 = 1,
    radiusY: f64 = 1,
    rotationAngle: f64 = 0,
    force: f64 = 1,
};

// https://w3c.github.io/touch-events/#dom-touchinit
const Init = struct {
    clientX: f64 = 0,
    clientY: f64 = 0,
    force: f32 = 0,
    identifier: i32,
    pageX: f64 = 0,
    pageY: f64 = 0,
    radiusX: f32 = 0,
    radiusY: f32 = 0,
    rotationAngle: f32 = 0,
    screenX: f64 = 0,
    screenY: f64 = 0,
    target: *EventTarget,
};

fn init(opts: Init, frame: *Frame) !*Touch {
    // All restricted: NaN or an infinity is a TypeError.
    const numbers = .{ opts.clientX, opts.clientY, opts.force, opts.pageX, opts.pageY, opts.radiusX, opts.radiusY, opts.rotationAngle, opts.screenX, opts.screenY };
    inline for (numbers) |n| {
        if (!std.math.isFinite(n)) {
            return frame.js.typeError("TouchInit member is not a finite number");
        }
    }
    return frame._factory.create(Touch{
        ._target = opts.target,
        ._point = .{
            .x = opts.clientX,
            .y = opts.clientY,
            .id = opts.identifier,
            .radiusX = opts.radiusX,
            .radiusY = opts.radiusY,
            .rotationAngle = opts.rotationAngle,
            .force = opts.force,
        },
        ._page_x = opts.pageX,
        ._page_y = opts.pageY,
        ._screen_x = opts.screenX,
        ._screen_y = opts.screenY,
    });
}

/// A touch from input. This engine has no layout, so its page and screen
/// coordinates alias the client ones, the same simplification
/// MouseEvent.compatCoordinate makes.
pub fn initTrusted(target: *EventTarget, point: Point, frame: *Frame) !*Touch {
    return frame._factory.create(Touch{
        ._target = target,
        ._point = point,
        ._page_x = point.x,
        ._page_y = point.y,
        ._screen_x = point.x,
        ._screen_y = point.y,
    });
}

pub fn deinit(self: *Touch, page: *Page) void {
    page.factory.destroy(self);
}

pub fn acquireRef(self: *Touch) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Touch, page: *Page) void {
    self._rc.release(self, page);
}

fn getIdentifier(self: *const Touch) i32 {
    return self._point.id;
}

fn getTarget(self: *const Touch) ?*EventTarget {
    return self._target;
}

fn getClientX(self: *const Touch) f64 {
    return self._point.x;
}

fn getClientY(self: *const Touch) f64 {
    return self._point.y;
}

fn getPageX(self: *const Touch) f64 {
    return self._page_x;
}

fn getPageY(self: *const Touch) f64 {
    return self._page_y;
}

fn getScreenX(self: *const Touch) f64 {
    return self._screen_x;
}

fn getScreenY(self: *const Touch) f64 {
    return self._screen_y;
}

fn getRadiusX(self: *const Touch) f64 {
    return self._point.radiusX;
}

fn getRadiusY(self: *const Touch) f64 {
    return self._point.radiusY;
}

fn getRotationAngle(self: *const Touch) f64 {
    return self._point.rotationAngle;
}

fn getForce(self: *const Touch) f64 {
    return self._point.force;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Touch);

    pub const Meta = struct {
        pub const name = "Touch";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Touch.init, .{});
    pub const identifier = bridge.accessor(Touch.getIdentifier, null, .{});
    pub const target = bridge.accessor(Touch.getTarget, null, .{});
    pub const clientX = bridge.accessor(Touch.getClientX, null, .{});
    pub const clientY = bridge.accessor(Touch.getClientY, null, .{});
    pub const pageX = bridge.accessor(Touch.getPageX, null, .{});
    pub const pageY = bridge.accessor(Touch.getPageY, null, .{});
    pub const screenX = bridge.accessor(Touch.getScreenX, null, .{});
    pub const screenY = bridge.accessor(Touch.getScreenY, null, .{});
    pub const radiusX = bridge.accessor(Touch.getRadiusX, null, .{});
    pub const radiusY = bridge.accessor(Touch.getRadiusY, null, .{});
    pub const rotationAngle = bridge.accessor(Touch.getRotationAngle, null, .{});
    pub const force = bridge.accessor(Touch.getForce, null, .{});
};
