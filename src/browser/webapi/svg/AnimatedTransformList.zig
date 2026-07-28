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
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const TransformList = @import("TransformList.zig");

const AnimatedTransformList = @This();

_base_val: *TransformList,
_anim_val: *TransformList,

pub const Kind = enum {
    transform,
    gradient_transform,
    pattern_transform,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .transform => .wrap("transform"),
            .gradient_transform => .wrap("gradientTransform"),
            .pattern_transform => .wrap("patternTransform"),
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedTransformList);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedTransformList {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_transform_lists.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_transform_lists.remove(key);
        gop.value_ptr.* = try createForAttribute(element, kind.attributeName(), frame);
    }
    return gop.value_ptr.*;
}

pub fn createForAttribute(element: *Element, attr_name: lp.String, frame: *Frame) !*AnimatedTransformList {
    const base_val = try TransformList.createForAttribute(element, attr_name, false, frame);
    const anim_val = try TransformList.createForAttribute(element, attr_name, true, frame);
    return frame._factory.create(AnimatedTransformList{
        ._base_val = base_val,
        ._anim_val = anim_val,
    });
}

pub fn deinit(self: *AnimatedTransformList, page: *Page) void {
    self._base_val.deinit(page);
    self._anim_val.deinit(page);
}

pub fn getBaseVal(self: *AnimatedTransformList) *TransformList {
    return self._base_val;
}

pub fn getAnimVal(self: *AnimatedTransformList) *TransformList {
    return self._anim_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedTransformList);

    pub const Meta = struct {
        pub const name = "SVGAnimatedTransformList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedTransformList.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(AnimatedTransformList.getAnimVal, null, .{});
};
