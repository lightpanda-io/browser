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

const AnimatedNumber = @This();

_element: *Element,
_attr_name: lp.String,
_allow_percentage: bool,

pub const Kind = enum {
    path_length,
    offset,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .path_length => comptime .wrap("pathLength"),
            .offset => comptime .wrap("offset"),
        };
    }

    fn allowsPercentage(self: Kind) bool {
        return switch (self) {
            .path_length => false,
            .offset => true,
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedNumber);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedNumber {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_numbers.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_numbers.remove(key);
        gop.value_ptr.* = try frame._factory.create(AnimatedNumber{
            ._element = element,
            ._attr_name = kind.attributeName(),
            ._allow_percentage = kind.allowsPercentage(),
        });
    }
    return gop.value_ptr.*;
}

pub fn getBaseVal(self: *const AnimatedNumber) f32 {
    return self.currentValue();
}

pub fn setBaseVal(self: *AnimatedNumber, value: f32, frame: *Frame) !void {
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }
    const serialized = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self._element.setAttributeSafe(self._attr_name, .wrap(serialized), frame);
}

pub fn getAnimVal(self: *const AnimatedNumber) f32 {
    return self.currentValue();
}

fn currentValue(self: *const AnimatedNumber) f32 {
    const raw = self._element.getAttributeSafe(self._attr_name) orelse return 0;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c");
    const value = if (self._allow_percentage and std.mem.endsWith(u8, trimmed, "%"))
        (std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 1]) catch return 0) / 100
    else
        std.fmt.parseFloat(f32, trimmed) catch return 0;
    return if (std.math.isFinite(value)) value else 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedNumber);

    pub const Meta = struct {
        pub const name = "SVGAnimatedNumber";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedNumber.getBaseVal, AnimatedNumber.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedNumber.getAnimVal, null, .{});
};
