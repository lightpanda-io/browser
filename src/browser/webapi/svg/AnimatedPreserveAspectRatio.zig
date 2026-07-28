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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const PreserveAspectRatio = @import("PreserveAspectRatio.zig");

const AnimatedPreserveAspectRatio = @This();

_base_val: *PreserveAspectRatio,
_anim_val: *PreserveAspectRatio,

pub const Lookup = std.AutoHashMapUnmanaged(*Element, *AnimatedPreserveAspectRatio);

pub fn getOrCreate(element: *Element, frame: *Frame) !*AnimatedPreserveAspectRatio {
    const gop = try frame._svg_animated_preserve_aspect_ratios.getOrPut(frame.arena, element);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_preserve_aspect_ratios.remove(element);
        gop.value_ptr.* = try create(element, frame);
    }
    return gop.value_ptr.*;
}

pub fn create(element: *Element, frame: *Frame) !*AnimatedPreserveAspectRatio {
    const base_val = try PreserveAspectRatio.create(element, false, frame);
    const anim_val = try PreserveAspectRatio.create(element, true, frame);
    return frame._factory.create(AnimatedPreserveAspectRatio{
        ._base_val = base_val,
        ._anim_val = anim_val,
    });
}

pub fn getBaseVal(self: *AnimatedPreserveAspectRatio) *PreserveAspectRatio {
    return self._base_val;
}

pub fn getAnimVal(self: *AnimatedPreserveAspectRatio) *PreserveAspectRatio {
    return self._anim_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedPreserveAspectRatio);

    pub const Meta = struct {
        pub const name = "SVGAnimatedPreserveAspectRatio";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedPreserveAspectRatio.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(AnimatedPreserveAspectRatio.getAnimVal, null, .{});
};
