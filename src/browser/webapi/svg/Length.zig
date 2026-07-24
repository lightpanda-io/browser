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

const String = lp.String;
const Length = @This();

_value: f64 = 0,
_unit: Unit = .number,
_element: ?*Element = null,
_attr_name: String = .empty,
_direction: Direction = .unspecified,
_read_only: bool = false,

pub const Direction = enum {
    horizontal,
    vertical,
    unspecified,
};

const Unit = enum(u16) {
    unknown = 0,
    number = 1,
    percentage = 2,
    em = 3,
    ex = 4,
    px = 5,
    cm = 6,
    mm = 7,
    in = 8,
    pt = 9,
    pc = 10,
};

const MAX_ANCESTOR_DEPTH = 32;

pub fn detached(frame: *Frame) !*Length {
    return frame._factory.create(Length{});
}

pub fn reflected(element: *Element, attr_name: String, direction: Direction, read_only: bool, frame: *Frame) !*Length {
    return frame._factory.create(Length{
        ._element = element,
        ._attr_name = attr_name,
        ._direction = direction,
        ._read_only = read_only,
    });
}

pub fn getUnitType(self: *Length) u16 {
    self.syncFromAttribute();
    return @intFromEnum(self._unit);
}

pub fn getValue(self: *Length, frame: *Frame) f64 {
    self.syncFromAttribute();
    return self._value * self.unitToUserUnits(self._unit, frame);
}

pub fn setValue(self: *Length, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    try ensureFinite(value);
    self._value = value;
    self._unit = .number;
    try self.writeBack(frame);
}

pub fn getValueInSpecifiedUnits(self: *Length) f64 {
    self.syncFromAttribute();
    return self._value;
}

pub fn setValueInSpecifiedUnits(self: *Length, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    try ensureFinite(value);
    self.syncFromAttribute();
    if (self._unit == .unknown) {
        self._unit = .number;
    }
    self._value = value;
    try self.writeBack(frame);
}

pub fn getValueAsString(self: *Length, frame: *Frame) ![]const u8 {
    self.syncFromAttribute();
    return self.serialize(frame);
}

pub fn setValueAsString(self: *Length, value: String, frame: *Frame) !void {
    try self.ensureWritable();
    const parsed = parse(value.str()) catch return error.SyntaxError;
    self._value = parsed.value;
    self._unit = parsed.unit;
    try self.writeBack(frame);
}

pub fn newValueSpecifiedUnits(self: *Length, unit_type: u16, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    const unit = try checkedUnit(unit_type);
    try ensureFinite(value);
    self._unit = unit;
    self._value = value;
    try self.writeBack(frame);
}

pub fn convertToSpecifiedUnits(self: *Length, unit_type: u16, frame: *Frame) !void {
    try self.ensureWritable();
    const target = try checkedUnit(unit_type);
    const absolute = self.getValue(frame);
    const factor = self.unitToUserUnits(target, frame);
    self._unit = target;
    self._value = if (factor == 0) 0 else absolute / factor;
    try self.writeBack(frame);
}

fn ensureWritable(self: *const Length) !void {
    if (self._read_only) {
        return error.NoModificationAllowed;
    }
}

fn ensureFinite(value: f64) !void {
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }
}

fn syncFromAttribute(self: *Length) void {
    const element = self._element orelse return;
    const raw = element.getAttributeSafe(self._attr_name) orelse {
        self._value = 0;
        self._unit = .number;
        return;
    };
    const parsed = parse(raw) catch {
        self._value = 0;
        self._unit = .unknown;
        return;
    };
    self._value = parsed.value;
    self._unit = parsed.unit;
}

fn writeBack(self: *Length, frame: *Frame) !void {
    const element = self._element orelse return;
    const value = try self.serialize(frame);
    try element.setAttributeSafe(self._attr_name, .wrap(value), frame);
}

fn serialize(self: *const Length, frame: *Frame) ![]const u8 {
    return std.fmt.allocPrint(frame.local_arena, "{d}{s}", .{ self._value, unitSuffix(self._unit) });
}

fn unitToUserUnits(self: *const Length, unit: Unit, frame: *Frame) f64 {
    if (absoluteUnitFactor(unit)) |factor| {
        return factor;
    }
    return switch (unit) {
        .unknown => 1,
        .percentage => self.percentageBasis(frame) / 100.0,
        .em => self.fontSize(frame),
        // Lightpanda does not load font metrics for DOM-only SVG values. CSS
        // defines 0.5em as the fallback when the x-height is unavailable.
        .ex => self.fontSize(frame) / 2.0,
        else => unreachable,
    };
}

fn percentageBasis(self: *const Length, frame: *Frame) f64 {
    const element = self._element orelse return 100;

    return switch (self._direction) {
        .horizontal => ancestorViewportDimension(element, .horizontal, frame),
        .vertical => ancestorViewportDimension(element, .vertical, frame),
        .unspecified => blk: {
            const width = ancestorViewportDimension(element, .horizontal, frame);
            const height = ancestorViewportDimension(element, .vertical, frame);
            break :blk @sqrt((width * width + height * height) / 2.0);
        },
    };
}

fn ancestorViewportDimension(element: *Element, direction: Direction, frame: *Frame) f64 {
    return ancestorViewportDimensionAt(element, direction, frame, 0);
}

fn ancestorViewportDimensionAt(element: *Element, direction: Direction, frame: *Frame, depth: u8) f64 {
    if (depth >= MAX_ANCESTOR_DEPTH) {
        return pageViewportDimension(direction, frame);
    }
    const viewport_element = nearestSvgViewport(element) orelse return pageViewportDimension(direction, frame);
    const attr_name: String = switch (direction) {
        .horizontal => comptime .wrap("width"),
        .vertical => comptime .wrap("height"),
        .unspecified => unreachable,
    };

    const raw = viewport_element.getAttributeSafe(attr_name) orelse {
        // SVG2 treats an omitted nested width/height as auto, whose used value
        // is 100% of the containing SVG viewport.
        return ancestorViewportDimensionAt(viewport_element, direction, frame, depth + 1);
    };
    const parsed = parse(raw) catch return ancestorViewportDimensionAt(viewport_element, direction, frame, depth + 1);
    return resolveParsedLength(parsed, viewport_element, direction, frame, depth + 1);
}

fn nearestSvgViewport(element: *Element) ?*Element {
    var current = element.parentElement();
    while (current) |parent| : (current = parent.parentElement()) {
        if (parent._namespace != .svg) return null;
        if (std.mem.eql(u8, parent.getTagNameLower(), "svg")) return parent;
    }
    return null;
}

fn pageViewportDimension(direction: Direction, frame: *Frame) f64 {
    const viewport = frame._page.getViewport();
    return switch (direction) {
        .horizontal => @floatFromInt(viewport.width),
        .vertical => @floatFromInt(viewport.height),
        .unspecified => unreachable,
    };
}

fn resolveParsedLength(parsed: Parsed, element: *Element, direction: Direction, frame: *Frame, depth: u8) f64 {
    const factor = absoluteUnitFactor(parsed.unit) orelse switch (parsed.unit) {
        .unknown => 1,
        .percentage => ancestorViewportDimensionAt(element, direction, frame, depth) / 100.0,
        .em => resolvedFontSizeAt(element, frame, depth),
        .ex => resolvedFontSizeAt(element, frame, depth) / 2.0,
        else => unreachable,
    };
    return parsed.value * factor;
}

fn fontSize(self: *const Length, frame: *Frame) f64 {
    return resolvedFontSize(self._element, frame);
}

// The style engine currently exposes inline declarations but does not compute
// stylesheet font inheritance. Resolve the sources it can represent exactly,
// then fall back to CSS's initial medium size (16px).
fn resolvedFontSize(element: ?*Element, frame: *Frame) f64 {
    return resolvedFontSizeAt(element, frame, 0);
}

fn resolvedFontSizeAt(element: ?*Element, frame: *Frame, depth: u8) f64 {
    if (depth >= MAX_ANCESTOR_DEPTH) {
        return 16;
    }
    const current = element orelse return 16;
    const parent = current.parentElement();

    if (frame._style_manager.inlineStyleValue(current, comptime .wrap("font-size"))) |raw| {
        if (parseFontSize(raw, parent, frame, depth + 1)) |size| {
            return size;
        }
    }
    if (current.getAttributeSafe(comptime .wrap("font-size"))) |raw| {
        if (parseFontSize(raw, parent, frame, depth + 1)) |size| {
            return size;
        }
    }
    return resolvedFontSizeAt(parent, frame, depth + 1);
}

fn parseFontSize(raw: []const u8, parent: ?*Element, frame: *Frame, depth: u8) ?f64 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset")) {
        return resolvedFontSizeAt(parent, frame, depth);
    }
    if (std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "medium")) {
        return 16;
    }

    const parsed = parse(value) catch return null;
    const parent_size = resolvedFontSizeAt(parent, frame, depth);
    const factor = absoluteUnitFactor(parsed.unit) orelse switch (parsed.unit) {
        .unknown => return null,
        .percentage => parent_size / 100.0,
        .em => parent_size,
        .ex => parent_size / 2.0,
        else => unreachable,
    };
    return parsed.value * factor;
}

fn absoluteUnitFactor(unit: Unit) ?f64 {
    return switch (unit) {
        .number, .px => 1,
        .cm => 96.0 / 2.54,
        .mm => 96.0 / 25.4,
        .in => 96,
        .pt => 96.0 / 72.0,
        .pc => 16,
        .unknown, .percentage, .em, .ex => null,
    };
}

const Parsed = struct {
    value: f64,
    unit: Unit,
};

fn parse(input: []const u8) !Parsed {
    const value = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (value.len == 0) {
        return error.SyntaxError;
    }

    const suffixes = [_]struct { []const u8, Unit }{
        .{ "%", .percentage },
        .{ "em", .em },
        .{ "ex", .ex },
        .{ "px", .px },
        .{ "cm", .cm },
        .{ "mm", .mm },
        .{ "in", .in },
        .{ "pt", .pt },
        .{ "pc", .pc },
    };

    for (suffixes) |entry| {
        const suffix, const unit = entry;
        if (value.len <= suffix.len) {
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix)) {
            continue;
        }
        const number = std.mem.trim(u8, value[0 .. value.len - suffix.len], " \t\r\n\x0c");
        return .{ .value = try parseNumber(number), .unit = unit };
    }

    return .{ .value = try parseNumber(value), .unit = .number };
}

fn parseNumber(value: []const u8) !f64 {
    const number = std.fmt.parseFloat(f64, value) catch return error.SyntaxError;
    if (!std.math.isFinite(number)) {
        return error.SyntaxError;
    }
    return number;
}

fn checkedUnit(value: u16) !Unit {
    return switch (value) {
        1 => .number,
        2 => .percentage,
        3 => .em,
        4 => .ex,
        5 => .px,
        6 => .cm,
        7 => .mm,
        8 => .in,
        9 => .pt,
        10 => .pc,
        else => error.NotSupported,
    };
}

fn unitSuffix(unit: Unit) []const u8 {
    return switch (unit) {
        .unknown, .number => "",
        .percentage => "%",
        .em => "em",
        .ex => "ex",
        .px => "px",
        .cm => "cm",
        .mm => "mm",
        .in => "in",
        .pt => "pt",
        .pc => "pc",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Length);

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

    pub const unitType = bridge.accessor(Length.getUnitType, null, .{});
    pub const value = bridge.accessor(Length.getValue, Length.setValue, .{});
    pub const valueInSpecifiedUnits = bridge.accessor(Length.getValueInSpecifiedUnits, Length.setValueInSpecifiedUnits, .{});
    pub const valueAsString = bridge.accessor(Length.getValueAsString, Length.setValueAsString, .{});
    pub const newValueSpecifiedUnits = bridge.function(Length.newValueSpecifiedUnits, .{});
    pub const convertToSpecifiedUnits = bridge.function(Length.convertToSpecifiedUnits, .{});
};
