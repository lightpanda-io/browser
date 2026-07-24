// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const Number = @import("Number.zig");

const AnimatedNumber = @This();

_base_val: *Number,
_anim_val: *Number,

pub const Lookup = std.AutoHashMapUnmanaged(*Element, *AnimatedNumber);

pub fn getOrCreate(element: *Element, frame: *Frame) !*AnimatedNumber {
    const gop = try frame._svg_animated_numbers.getOrPut(frame.arena, element);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_numbers.remove(element);
        gop.value_ptr.* = try create(element, comptime .wrap("pathLength"), frame);
    }
    return gop.value_ptr.*;
}

pub fn getOrCreatePercentage(element: *Element, frame: *Frame) !*AnimatedNumber {
    const gop = try frame._svg_animated_numbers.getOrPut(frame.arena, element);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_numbers.remove(element);
        gop.value_ptr.* = try createPercentage(element, comptime .wrap("offset"), frame);
    }
    return gop.value_ptr.*;
}

pub fn create(element: *Element, attr_name: lp.String, frame: *Frame) !*AnimatedNumber {
    const base_val = try Number.reflected(element, attr_name, false, frame);
    const anim_val = try Number.reflected(element, attr_name, true, frame);
    return frame._factory.create(AnimatedNumber{
        ._base_val = base_val,
        ._anim_val = anim_val,
    });
}

pub fn createPercentage(element: *Element, attr_name: lp.String, frame: *Frame) !*AnimatedNumber {
    const base_val = try Number.reflectedPercentage(element, attr_name, false, frame);
    const anim_val = try Number.reflectedPercentage(element, attr_name, true, frame);
    return frame._factory.create(AnimatedNumber{
        ._base_val = base_val,
        ._anim_val = anim_val,
    });
}

pub fn getBaseVal(self: *AnimatedNumber) *Number {
    return self._base_val;
}

pub fn getAnimVal(self: *AnimatedNumber) *Number {
    return self._anim_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedNumber);

    pub const Meta = struct {
        pub const name = "SVGAnimatedNumber";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedNumber.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(AnimatedNumber.getAnimVal, null, .{});
};
