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

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .x => comptime .wrap("x"),
            .y => comptime .wrap("y"),
            .width => comptime .wrap("width"),
            .height => comptime .wrap("height"),
        };
    }

    fn direction(self: Kind) Length.Direction {
        return switch (self) {
            .x, .width => .horizontal,
            .y, .height => .vertical,
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
        gop.value_ptr.* = try create(element, kind.attributeName(), kind.direction(), frame);
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
