// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const SVGAngle = @This();

const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const String = @import("../../../string.zig").String;

_value: f64,
_unit_type: u16,
_element: ?*Element,
_attr_name: String,

pub fn getUnitType(self: *const SVGAngle) u16 {
    return self._unit_type;
}

pub fn getValue(self: *const SVGAngle) f64 {
    return self._value;
}

pub fn setValue(self: *SVGAngle, value: f64, page: *Page) !void {
    self._value = value;
    try self.writeBack(page);
}

pub fn getValueInSpecifiedUnits(self: *const SVGAngle) f64 {
    return self._value;
}

pub fn getValueAsString(self: *const SVGAngle) []const u8 {
    if (self._element) |elem| {
        return elem.getAttributeSafe(self._attr_name) orelse "";
    }
    return "";
}

pub fn newValueSpecifiedUnits(self: *SVGAngle, unit_type: u16, value: f64, page: *Page) !void {
    self._unit_type = unit_type;
    self._value = value;
    try self.writeBack(page);
}

pub fn convertToSpecifiedUnits(self: *SVGAngle, unit_type: u16) void {
    self._unit_type = unit_type;
}

fn writeBack(self: *SVGAngle, page: *Page) !void {
    if (self._element) |elem| {
        var buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{self._value}) catch return;
        try elem.setAttributeSafe(self._attr_name, String.wrap(str), page);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGAngle);

    pub const Meta = struct {
        pub const name = "SVGAngle";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_ANGLETYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_ANGLETYPE_UNSPECIFIED = bridge.property(1, .{ .template = true });
    pub const SVG_ANGLETYPE_DEG = bridge.property(2, .{ .template = true });
    pub const SVG_ANGLETYPE_RAD = bridge.property(3, .{ .template = true });
    pub const SVG_ANGLETYPE_GRAD = bridge.property(4, .{ .template = true });

    pub const unitType = bridge.accessor(SVGAngle.getUnitType, null, .{});
    pub const value = bridge.accessor(SVGAngle.getValue, SVGAngle.setValue, .{});
    pub const valueInSpecifiedUnits = bridge.accessor(SVGAngle.getValueInSpecifiedUnits, null, .{});
    pub const valueAsString = bridge.accessor(SVGAngle.getValueAsString, null, .{});
    pub const newValueSpecifiedUnits = bridge.function(SVGAngle.newValueSpecifiedUnits, .{});
    pub const convertToSpecifiedUnits = bridge.function(SVGAngle.convertToSpecifiedUnits, .{});
};
