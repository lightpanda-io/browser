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

const Number = @This();
_value: f32 = 0,
_element: ?*Element = null,
_attr_name: lp.String = .empty,
_read_only: bool = false,
_allow_percentage: bool = false,

pub fn detached(frame: *Frame) !*Number {
    return frame._factory.create(Number{});
}

pub fn reflected(element: *Element, attr_name: lp.String, read_only: bool, frame: *Frame) !*Number {
    return frame._factory.create(Number{
        ._element = element,
        ._attr_name = attr_name,
        ._read_only = read_only,
    });
}

pub fn reflectedPercentage(element: *Element, attr_name: lp.String, read_only: bool, frame: *Frame) !*Number {
    return frame._factory.create(Number{
        ._element = element,
        ._attr_name = attr_name,
        ._read_only = read_only,
        ._allow_percentage = true,
    });
}

pub fn getValue(self: *Number) f32 {
    self.syncFromAttribute();
    return self._value;
}

pub fn setValue(self: *Number, value: f32, frame: *Frame) !void {
    if (self._read_only) return error.NoModificationAllowed;
    if (!std.math.isFinite(value)) return error.TypeError;
    self._value = value;
    const element = self._element orelse return;
    const serialized = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try element.setAttributeSafe(self._attr_name, lp.String.wrap(serialized), frame);
}

fn syncFromAttribute(self: *Number) void {
    const element = self._element orelse return;
    const raw = element.getAttributeSafe(self._attr_name) orelse {
        self._value = 0;
        return;
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (self._allow_percentage and std.mem.endsWith(u8, trimmed, "%")) {
        self._value = (std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 1]) catch 0) / 100;
    } else {
        self._value = std.fmt.parseFloat(f32, trimmed) catch 0;
    }
    if (!std.math.isFinite(self._value)) self._value = 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Number);

    pub const Meta = struct {
        pub const name = "SVGNumber";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(Number.getValue, Number.setValue, .{});
};
