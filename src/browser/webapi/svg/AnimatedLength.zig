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
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const Length = @import("Length.zig");

const AnimatedLength = @This();

_base_val: *Length,
_anim_val: *Length,

pub const Kind = enum {
    x,
    y,
    width,
    height,
    cx,
    cy,
    r,
    rx,
    ry,
    x1,
    y1,
    x2,
    y2,
    linear_gradient_x1,
    linear_gradient_y1,
    linear_gradient_x2,
    linear_gradient_y2,
    radial_gradient_cx,
    radial_gradient_cy,
    radial_gradient_r,
    radial_gradient_fx,
    radial_gradient_fy,
    radial_gradient_fr,
    marker_ref_x,
    marker_ref_y,
    marker_width,
    marker_height,
    mask_x,
    mask_y,
    mask_width,
    mask_height,
    pattern_x,
    pattern_y,
    pattern_width,
    pattern_height,
    text_length,
    text_path_start_offset,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .x, .mask_x, .pattern_x => comptime .wrap("x"),
            .y, .mask_y, .pattern_y => comptime .wrap("y"),
            .width, .mask_width, .pattern_width => comptime .wrap("width"),
            .height, .mask_height, .pattern_height => comptime .wrap("height"),
            .cx, .radial_gradient_cx => comptime .wrap("cx"),
            .cy, .radial_gradient_cy => comptime .wrap("cy"),
            .r, .radial_gradient_r => comptime .wrap("r"),
            .rx => comptime .wrap("rx"),
            .ry => comptime .wrap("ry"),
            .x1, .linear_gradient_x1 => comptime .wrap("x1"),
            .y1, .linear_gradient_y1 => comptime .wrap("y1"),
            .x2, .linear_gradient_x2 => comptime .wrap("x2"),
            .y2, .linear_gradient_y2 => comptime .wrap("y2"),
            .radial_gradient_fx => comptime .wrap("fx"),
            .radial_gradient_fy => comptime .wrap("fy"),
            .radial_gradient_fr => comptime .wrap("fr"),
            .marker_ref_x => comptime .wrap("refX"),
            .marker_ref_y => comptime .wrap("refY"),
            .marker_width => comptime .wrap("markerWidth"),
            .marker_height => comptime .wrap("markerHeight"),
            .text_length => comptime .wrap("textLength"),
            .text_path_start_offset => comptime .wrap("startOffset"),
        };
    }

    fn direction(self: Kind) Length.Direction {
        return switch (self) {
            .x,
            .width,
            .cx,
            .rx,
            .x1,
            .x2,
            .linear_gradient_x1,
            .linear_gradient_x2,
            .radial_gradient_cx,
            .radial_gradient_fx,
            .marker_ref_x,
            .marker_width,
            .mask_x,
            .mask_width,
            .pattern_x,
            .pattern_width,
            .text_length,
            => .horizontal,
            .y,
            .height,
            .cy,
            .ry,
            .y1,
            .y2,
            .linear_gradient_y1,
            .linear_gradient_y2,
            .radial_gradient_cy,
            .radial_gradient_fy,
            .marker_ref_y,
            .marker_height,
            .mask_y,
            .mask_height,
            .pattern_y,
            .pattern_height,
            => .vertical,
            .r, .radial_gradient_r, .radial_gradient_fr, .text_path_start_offset => .unspecified,
        };
    }

    fn defaultValue(self: Kind) f64 {
        return switch (self) {
            .linear_gradient_x2 => 100,
            .radial_gradient_cx,
            .radial_gradient_cy,
            .radial_gradient_r,
            .radial_gradient_fx,
            .radial_gradient_fy,
            => 50,
            .marker_width, .marker_height => 3,
            .mask_x, .mask_y => -10,
            .mask_width, .mask_height => 120,
            else => 0,
        };
    }

    fn defaultUnit(self: Kind) Length.Unit {
        return switch (self) {
            .linear_gradient_x1,
            .linear_gradient_y1,
            .linear_gradient_x2,
            .linear_gradient_y2,
            .radial_gradient_cx,
            .radial_gradient_cy,
            .radial_gradient_r,
            .radial_gradient_fx,
            .radial_gradient_fy,
            .radial_gradient_fr,
            .mask_x,
            .mask_y,
            .mask_width,
            .mask_height,
            => .percentage,
            else => .number,
        };
    }

    fn fallbackAttributeName(self: Kind) ?lp.String {
        return switch (self) {
            .radial_gradient_fx => comptime .wrap("cx"),
            .radial_gradient_fy => comptime .wrap("cy"),
            else => null,
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedLength);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedLength {
    const key: Key = .{
        .element = element,
        .kind = kind,
    };
    const gop = try frame._svg_animated_lengths.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_lengths.remove(key);
        gop.value_ptr.* = try createConfigured(
            element,
            kind.attributeName(),
            kind.direction(),
            kind.defaultValue(),
            kind.defaultUnit(),
            kind.fallbackAttributeName(),
            frame,
        );
    }
    return gop.value_ptr.*;
}

pub fn create(element: *Element, attr_name: lp.String, direction: Length.Direction, frame: *Frame) !*AnimatedLength {
    const base_val = try Length.reflected(element, attr_name, direction, false, frame);
    const anim_val = try Length.reflected(element, attr_name, direction, true, frame);
    return frame._factory.create(AnimatedLength{
        ._base_val = base_val,
        ._anim_val = anim_val,
    });
}

pub fn createConfigured(
    element: *Element,
    attr_name: lp.String,
    direction: Length.Direction,
    default_value: f64,
    default_unit: Length.Unit,
    fallback_attr_name: ?lp.String,
    frame: *Frame,
) !*AnimatedLength {
    const base_val = try Length.reflectedConfigured(
        element,
        attr_name,
        direction,
        default_value,
        default_unit,
        fallback_attr_name,
        false,
        frame,
    );
    const anim_val = try Length.reflectedConfigured(
        element,
        attr_name,
        direction,
        default_value,
        default_unit,
        fallback_attr_name,
        true,
        frame,
    );
    return frame._factory.create(AnimatedLength{
        ._base_val = base_val,
        ._anim_val = anim_val,
    });
}

pub fn getBaseVal(self: *AnimatedLength) *Length {
    return self._base_val;
}

pub fn getAnimVal(self: *AnimatedLength) *Length {
    return self._anim_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedLength);

    pub const Meta = struct {
        pub const name = "SVGAnimatedLength";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedLength.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(AnimatedLength.getAnimVal, null, .{});
};
