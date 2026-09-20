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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const EventTarget = @import("../EventTarget.zig");
const TouchEvent = @import("TouchEvent.zig");

// https://w3c.github.io/touch-events/#idl-def-touch
//
// Stored by value inside its TouchEvent, so its address is stable for the
// event's lifetime and refcounting delegates to the event.
const Touch = @This();

_event: *TouchEvent,
_identifier: i32,
// EventTarget, not Element, per spec, and because dispatch retargets it
// across shadow boundaries the same way it retargets Event.target (see
// TouchEvent.touchTargetPtr / EventManager's AdjustedTargets).
_target: ?*EventTarget,
_client_x: f64,
_client_y: f64,

pub fn acquireRef(self: *Touch) void {
    self._event.asEvent().acquireRef();
}

pub fn releaseRef(self: *Touch, page: *Page) void {
    self._event.asEvent().releaseRef(page);
}

fn getIdentifier(self: *const Touch) i32 {
    return self._identifier;
}

fn getTarget(self: *const Touch) ?*EventTarget {
    return self._target;
}

fn getClientX(self: *const Touch) f64 {
    return self._client_x;
}

fn getClientY(self: *const Touch) f64 {
    return self._client_y;
}

/// This engine has no layout, so screenX/screenY and pageX/pageY alias
/// clientX/clientY, the same simplification MouseEvent.compatCoordinate
/// makes (there, scrollX/scrollY are tracked but not yet folded in either).
fn getPageX(self: *const Touch) f64 {
    return self._client_x;
}

fn getPageY(self: *const Touch) f64 {
    return self._client_y;
}

fn getScreenX(self: *const Touch) f64 {
    return self._client_x;
}

fn getScreenY(self: *const Touch) f64 {
    return self._client_y;
}

/// No hit-testing geometry in this engine: default to Chrome's synthetic
/// values for a single-point contact (a 1x1 circle, no rotation, full force).
fn getRadiusX(_: *const Touch) f64 {
    return 1;
}

fn getRadiusY(_: *const Touch) f64 {
    return 1;
}

fn getRotationAngle(_: *const Touch) f64 {
    return 0;
}

fn getForce(_: *const Touch) f64 {
    return 1;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Touch);

    pub const Meta = struct {
        pub const name = "Touch";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

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
