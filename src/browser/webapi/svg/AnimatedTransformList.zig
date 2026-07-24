// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const TransformList = @import("TransformList.zig");

const AnimatedTransformList = @This();

_base_val: *TransformList,
_anim_val: *TransformList,

pub fn create(element: *Element, frame: *Frame) !*AnimatedTransformList {
    const base_val = try TransformList.create(element, false, frame);
    const anim_val = try TransformList.create(element, true, frame);
    return frame._factory.create(AnimatedTransformList{
        ._base_val = base_val,
        ._anim_val = anim_val,
    });
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
