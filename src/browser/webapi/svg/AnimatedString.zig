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

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedString);

const String = lp.String;

const AnimatedString = @This();

_kind: Kind,
_element: *Element,

pub const Kind = enum { class, href };
pub const Key = struct {
    element: *Element,
    kind: Kind,
};

// Identity map for AnimatedString, help by the frame
pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedString {
    const gop = try frame._svg_animated_strings.getOrPut(frame.arena, .{ .element = element, .kind = kind });
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(AnimatedString{
            ._element = element,
            ._kind = kind,
        });
    }
    return gop.value_ptr.*;
}

pub fn getBaseVal(self: *const AnimatedString) []const u8 {
    return self._element.getAttributeSafe(self.attributeName()) orelse "";
}

pub fn setBaseVal(self: *AnimatedString, value: String, frame: *Frame) !void {
    try self._element.setAttribute(self.attributeName(), value, frame);
}

// No real animation, return the BaseVal
pub fn getAnimVal(self: *const AnimatedString) []const u8 {
    return self.getBaseVal();
}

fn attributeName(self: *const AnimatedString) String {
    return switch (self._kind) {
        .href => comptime .wrap("href"),
        .class => comptime .wrap("class"),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedString);

    pub const Meta = struct {
        pub const name = "SVGAnimatedString";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedString.getBaseVal, AnimatedString.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedString.getAnimVal, null, .{});
};
