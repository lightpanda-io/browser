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

const SVGLength = @This();

const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const String = @import("../../../string.zig").String;

const Node = @import("../Node.zig");

_value: f64,
_unit_type: u16,
_element: ?*Element,
_attr_name: String,

fn unitToPx(unit_type: u16) f64 {
    return switch (unit_type) {
        1, 5 => 1.0, // NUMBER, PX
        6 => 96.0 / 2.54, // CM
        7 => 96.0 / 25.4, // MM
        8 => 96.0, // IN
        9 => 96.0 / 72.0, // PT
        10 => 96.0 / 6.0, // PC
        else => 1.0, // %, em, ex handled in resolveRelativeUnit
    };
}

/// Resolve relative units (%, em, ex) using element context.
fn resolveRelativeUnit(self: *SVGLength) f64 {
    return switch (self._unit_type) {
        3 => self._value * resolveFontSize(self._element), // em
        4 => self._value * resolveFontSize(self._element) * 0.5, // ex ≈ 0.5em
        2 => self._value * resolveViewportDim(self._element, self._attr_name) / 100.0, // %
        else => self._value * unitToPx(self._unit_type),
    };
}

fn resolveFontSize(element: ?*Element) f64 {
    const el = element orelse return 16;
    var current: ?*Element = el;
    while (current) |cur| {
        const style = cur.getAttributeSafe(comptime String.wrap("style")) orelse {
            current = cur.asNode().parentElement();
            continue;
        };
        if (std.mem.indexOf(u8, style, "font-size:")) |idx| {
            const rest = std.mem.trimLeft(u8, style[idx + 10 ..], " ");
            var end: usize = 0;
            while (end < rest.len and (rest[end] >= '0' and rest[end] <= '9' or rest[end] == '.')) : (end += 1) {}
            if (end > 0) return std.fmt.parseFloat(f64, rest[0..end]) catch 16;
        }
        current = cur.asNode().parentElement();
    }
    return 16; // default
}

fn resolveViewportDim(element: ?*Element, attr_name: String) f64 {
    const name = attr_name.str();
    const is_vertical = std.mem.eql(u8, name, "y") or std.mem.eql(u8, name, "height") or
        std.mem.eql(u8, name, "cy") or std.mem.eql(u8, name, "ry") or
        std.mem.eql(u8, name, "y1") or std.mem.eql(u8, name, "y2");
    // Walk up to find nearest <svg> root element (skip self)
    var current: ?*Element = if (element) |el| el.asNode().parentElement() else null;
    while (current) |cur| {
        if (cur.getTag() == .svg) {
            const dim_attr = cur.getAttributeSafe(if (is_vertical) comptime String.wrap("height") else comptime String.wrap("width"));
            if (dim_attr) |val| {
                var end: usize = 0;
                while (end < val.len and (val[end] >= '0' and val[end] <= '9' or val[end] == '.')) : (end += 1) {}
                if (end > 0) {
                    if (std.fmt.parseFloat(f64, val[0..end])) |v| return v else |_| {}
                }
            }
            // Fallback: parse viewBox
            const vb = cur.getAttributeSafe(comptime String.wrap("viewBox")) orelse {
                current = cur.asNode().parentElement();
                continue;
            };
            var it = std.mem.tokenizeAny(u8, vb, " ,");
            _ = it.next(); // skip x
            _ = it.next(); // skip y
            if (is_vertical) {
                _ = it.next(); // skip w
                if (it.next()) |h| return std.fmt.parseFloat(f64, h) catch 300;
            } else {
                if (it.next()) |w| return std.fmt.parseFloat(f64, w) catch 300;
            }
        }
        current = cur.asNode().parentElement();
    }
    return 300;
}

fn unitSuffix(unit_type: u16) []const u8 {
    return switch (unit_type) {
        1 => "",
        2 => "%",
        3 => "em",
        4 => "ex",
        5 => "px",
        6 => "cm",
        7 => "mm",
        8 => "in",
        9 => "pt",
        10 => "pc",
        else => "",
    };
}

fn parseAttrValue(attr: []const u8) struct { value: f64, unit_type: u16 } {
    var end: usize = 0;
    while (end < attr.len) : (end += 1) {
        const c = attr[end];
        if (c >= '0' and c <= '9' or c == '.' or ((c == '-' or c == '+') and end == 0)) continue;
        if ((c == 'e' or c == 'E') and end > 0 and end + 1 < attr.len and
            (attr[end + 1] >= '0' and attr[end + 1] <= '9' or attr[end + 1] == '-' or attr[end + 1] == '+')) {
            end += 1; // skip sign/first exponent digit so it's consumed
            continue;
        }
        break;
    }
    const num = std.fmt.parseFloat(f64, attr[0..end]) catch return .{ .value = 0, .unit_type = 1 };
    const suffix = std.mem.trimLeft(u8, attr[end..], " ");
    const ut: u16 = if (std.mem.eql(u8, suffix, "px")) 5 else if (std.mem.eql(u8, suffix, "cm")) 6 else if (std.mem.eql(u8, suffix, "mm")) 7 else if (std.mem.eql(u8, suffix, "in")) 8 else if (std.mem.eql(u8, suffix, "pt")) 9 else if (std.mem.eql(u8, suffix, "pc")) 10 else if (std.mem.eql(u8, suffix, "em")) 3 else if (std.mem.eql(u8, suffix, "ex")) 4 else if (std.mem.eql(u8, suffix, "%")) 2 else 1;
    return .{ .value = num, .unit_type = ut };
}

fn syncFromAttr(self: *SVGLength) void {
    if (self._element) |elem| {
        const attr = elem.getAttributeSafe(self._attr_name) orelse return;
        const parsed = parseAttrValue(attr);
        self._value = parsed.value;
        self._unit_type = parsed.unit_type;
    }
}

pub fn getUnitType(self: *SVGLength) u16 {
    self.syncFromAttr();
    return self._unit_type;
}

pub fn getValue(self: *SVGLength) f64 {
    self.syncFromAttr();
    return self.resolveRelativeUnit();
}

pub fn setValue(self: *SVGLength, value: f64, page: *Page) !void {
    self.syncFromAttr();
    // Convert px value to the current unit
    switch (self._unit_type) {
        2 => { // %
            const vp = resolveViewportDim(self._element, self._attr_name);
            self._value = if (vp != 0) value * 100.0 / vp else value;
        },
        3 => { // em
            const fs = resolveFontSize(self._element);
            self._value = if (fs != 0) value / fs else value;
        },
        4 => { // ex
            const fs = resolveFontSize(self._element) * 0.5;
            self._value = if (fs != 0) value / fs else value;
        },
        else => {
            const factor = unitToPx(self._unit_type);
            self._value = value / factor;
        },
    }
    try self.writeBack(page);
}

pub fn getValueInSpecifiedUnits(self: *SVGLength) f64 {
    self.syncFromAttr();
    return self._value;
}

pub fn getValueAsString(self: *SVGLength, page: *Page) ![]const u8 {
    self.syncFromAttr();
    const suffix = unitSuffix(self._unit_type);
    var buf: [64]u8 = undefined;
    const num = formatSvgFloat(&buf, self._value);
    return std.fmt.allocPrint(page.call_arena, "{s}{s}", .{ num, suffix });
}

pub fn newValueSpecifiedUnits(self: *SVGLength, unit_type: u16, value: f64, page: *Page) !void {
    self._unit_type = unit_type;
    self._value = value;
    try self.writeBack(page);
}

pub fn convertToSpecifiedUnits(self: *SVGLength, unit_type: u16, page: *Page) !void {
    self.syncFromAttr();
    // Get current value in px using full resolution (including relative units)
    const px = self.resolveRelativeUnit();
    self._unit_type = unit_type;
    // Convert px to the target unit
    switch (unit_type) {
        2 => { // %
            const vp = resolveViewportDim(self._element, self._attr_name);
            self._value = if (vp != 0) px * 100.0 / vp else px;
        },
        3 => { // em
            const fs = resolveFontSize(self._element);
            self._value = if (fs != 0) px / fs else px;
        },
        4 => { // ex
            const fs = resolveFontSize(self._element) * 0.5;
            self._value = if (fs != 0) px / fs else px;
        },
        else => {
            self._value = px / unitToPx(unit_type);
        },
    }
    try self.writeBack(page);
}

fn writeBack(self: *SVGLength, page: *Page) !void {
    if (self._element) |elem| {
        const suffix = unitSuffix(self._unit_type);
        var buf: [64]u8 = undefined;
        const num = formatSvgFloat(&buf, self._value);
        const str = try std.fmt.allocPrint(page.call_arena, "{s}{s}", .{ num, suffix });
        try elem.setAttributeSafe(self._attr_name, String.wrap(str), page);
    }
}

fn formatSvgFloat(buf: *[64]u8, value: f64) []const u8 {
    const str = std.fmt.bufPrint(buf, "{d:.10}", .{value}) catch return "0";
    if (std.mem.indexOf(u8, str, ".")) |dot| {
        var end = str.len;
        while (end > dot + 1 and str[end - 1] == '0') : (end -= 1) {}
        if (end == dot + 1) end = dot; // remove trailing dot
        return str[0..end];
    }
    return str;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGLength);

    pub const Meta = struct {
        pub const name = "SVGLength";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_LENGTHTYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_LENGTHTYPE_NUMBER = bridge.property(1, .{ .template = true });
    pub const SVG_LENGTHTYPE_PERCENTAGE = bridge.property(2, .{ .template = true });
    pub const SVG_LENGTHTYPE_EMS = bridge.property(3, .{ .template = true });
    pub const SVG_LENGTHTYPE_EXS = bridge.property(4, .{ .template = true });
    pub const SVG_LENGTHTYPE_PX = bridge.property(5, .{ .template = true });
    pub const SVG_LENGTHTYPE_CM = bridge.property(6, .{ .template = true });
    pub const SVG_LENGTHTYPE_MM = bridge.property(7, .{ .template = true });
    pub const SVG_LENGTHTYPE_IN = bridge.property(8, .{ .template = true });
    pub const SVG_LENGTHTYPE_PT = bridge.property(9, .{ .template = true });
    pub const SVG_LENGTHTYPE_PC = bridge.property(10, .{ .template = true });

    pub const unitType = bridge.accessor(SVGLength.getUnitType, null, .{});
    pub const value = bridge.accessor(SVGLength.getValue, SVGLength.setValue, .{});
    pub const valueInSpecifiedUnits = bridge.accessor(SVGLength.getValueInSpecifiedUnits, null, .{});
    pub const valueAsString = bridge.accessor(SVGLength.getValueAsString, null, .{});
    pub const newValueSpecifiedUnits = bridge.function(SVGLength.newValueSpecifiedUnits, .{});
    pub const convertToSpecifiedUnits = bridge.function(SVGLength.convertToSpecifiedUnits, .{});
};
