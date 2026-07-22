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
const Angle = @This();

_value: f64 = 0,
_unit: Unit = .unspecified,
_element: ?*Element = null,
_attr_name: String = .empty,
_read_only: bool = false,

const Unit = enum(u16) {
    unknown = 0,
    unspecified = 1,
    deg = 2,
    rad = 3,
    grad = 4,
    turn = 5,
};

pub fn detached(frame: *Frame) !*Angle {
    return frame._factory.create(Angle{});
}

pub fn getUnitType(self: *Angle) u16 {
    self.syncFromAttribute();
    return switch (self._unit) {
        .turn => 0,
        else => @intFromEnum(self._unit),
    };
}

pub fn getValue(self: *Angle) f64 {
    self.syncFromAttribute();
    return toDegrees(self._value, self._unit);
}

pub fn setValue(self: *Angle, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    try ensureFinite(value);
    self._value = value;
    self._unit = .unspecified;
    try self.writeBack(frame);
}

pub fn getValueInSpecifiedUnits(self: *Angle) f64 {
    self.syncFromAttribute();
    return self._value;
}

pub fn setValueInSpecifiedUnits(self: *Angle, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    try ensureFinite(value);
    self.syncFromAttribute();
    if (self._unit == .unknown) {
        self._unit = .unspecified;
    }
    self._value = value;
    try self.writeBack(frame);
}

pub fn getValueAsString(self: *Angle, frame: *Frame) ![]const u8 {
    self.syncFromAttribute();
    return self.serialize(frame);
}

pub fn setValueAsString(self: *Angle, value: String, frame: *Frame) !void {
    try self.ensureWritable();
    const parsed = parse(value.str()) catch return error.SyntaxError;
    self._value = parsed.value;
    self._unit = parsed.unit;
    try self.writeBack(frame);
}

pub fn newValueSpecifiedUnits(self: *Angle, unit_type: u16, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    const unit = try checkedUnit(unit_type);
    try ensureFinite(value);
    self._unit = unit;
    self._value = value;
    try self.writeBack(frame);
}

pub fn convertToSpecifiedUnits(self: *Angle, unit_type: u16, frame: *Frame) !void {
    try self.ensureWritable();
    const target = try checkedUnit(unit_type);
    const degrees = self.getValue();
    self._unit = target;
    self._value = fromDegrees(degrees, target);
    try self.writeBack(frame);
}

fn ensureWritable(self: *const Angle) !void {
    if (self._read_only) {
        return error.NoModificationAllowed;
    }
}

fn ensureFinite(value: f64) !void {
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }
}

fn syncFromAttribute(self: *Angle) void {
    const element = self._element orelse return;
    const raw = element.getAttributeSafe(self._attr_name) orelse {
        self._value = 0;
        self._unit = .unspecified;
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

fn writeBack(self: *Angle, frame: *Frame) !void {
    const element = self._element orelse return;
    const value = try self.serialize(frame);
    try element.setAttributeSafe(self._attr_name, .wrap(value), frame);
}

fn serialize(self: *const Angle, frame: *Frame) ![]const u8 {
    return std.fmt.allocPrint(frame.local_arena, "{d}{s}", .{ self._value, unitSuffix(self._unit) });
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
        .{ "turn", .turn },
        .{ "grad", .grad },
        .{ "deg", .deg },
        .{ "rad", .rad },
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
    return .{ .value = try parseNumber(value), .unit = .unspecified };
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
        1 => .unspecified,
        2 => .deg,
        3 => .rad,
        4 => .grad,
        else => error.NotSupported,
    };
}

fn toDegrees(value: f64, unit: Unit) f64 {
    return switch (unit) {
        .unknown, .unspecified, .deg => value,
        .rad => value * 180.0 / std.math.pi,
        .grad => value * 0.9,
        .turn => value * 360.0,
    };
}

fn fromDegrees(value: f64, unit: Unit) f64 {
    return switch (unit) {
        .unknown, .unspecified, .deg => value,
        .rad => value * std.math.pi / 180.0,
        .grad => value / 0.9,
        .turn => value / 360.0,
    };
}

fn unitSuffix(unit: Unit) []const u8 {
    return switch (unit) {
        .unknown, .unspecified => "",
        .deg => "deg",
        .rad => "rad",
        .grad => "grad",
        .turn => "turn",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Angle);

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

    pub const unitType = bridge.accessor(Angle.getUnitType, null, .{});
    pub const value = bridge.accessor(Angle.getValue, Angle.setValue, .{});
    pub const valueInSpecifiedUnits = bridge.accessor(Angle.getValueInSpecifiedUnits, Angle.setValueInSpecifiedUnits, .{});
    pub const valueAsString = bridge.accessor(Angle.getValueAsString, Angle.setValueAsString, .{});
    pub const newValueSpecifiedUnits = bridge.function(Angle.newValueSpecifiedUnits, .{});
    pub const convertToSpecifiedUnits = bridge.function(Angle.convertToSpecifiedUnits, .{});
};
