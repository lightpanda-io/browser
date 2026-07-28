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
const PreserveAspectRatio = @This();

_element: *Element,
_read_only: bool = false,

const Value = struct {
    alignment: u16 = 6,
    meet_or_slice: u16 = 1,
};

pub fn create(element: *Element, read_only: bool, frame: *Frame) !*PreserveAspectRatio {
    return frame._factory.create(PreserveAspectRatio{
        ._element = element,
        ._read_only = read_only,
    });
}

pub fn getAlign(self: *const PreserveAspectRatio) u16 {
    return self.current().alignment;
}

pub fn setAlign(self: *PreserveAspectRatio, alignment: u16, frame: *Frame) !void {
    try self.ensureWritable();
    if (alignName(alignment) == null) return error.TypeError;
    var value = self.current();
    value.alignment = alignment;
    try self.write(value, frame);
}

pub fn getMeetOrSlice(self: *const PreserveAspectRatio) u16 {
    return self.current().meet_or_slice;
}

pub fn setMeetOrSlice(self: *PreserveAspectRatio, meet_or_slice: u16, frame: *Frame) !void {
    try self.ensureWritable();
    if (meetOrSliceName(meet_or_slice) == null) return error.TypeError;
    var value = self.current();
    value.meet_or_slice = meet_or_slice;
    try self.write(value, frame);
}

fn ensureWritable(self: *const PreserveAspectRatio) !void {
    if (self._read_only) {
        return error.NoModificationAllowed;
    }
}

fn current(self: *const PreserveAspectRatio) Value {
    const raw = self._element.getAttributeSafe(String.wrap("preserveAspectRatio")) orelse return .{};
    var parts = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c");
    const alignment = alignValue(parts.next() orelse return .{}) orelse return .{};
    const meet_or_slice = meetOrSliceValue(parts.next() orelse "meet") orelse return .{};
    if (parts.next() != null) {
        return .{};
    }
    return .{ .alignment = alignment, .meet_or_slice = meet_or_slice };
}

fn write(self: *PreserveAspectRatio, value: Value, frame: *Frame) !void {
    const alignment = alignName(value.alignment) orelse return error.TypeError;
    const meet_or_slice = meetOrSliceName(value.meet_or_slice) orelse return error.TypeError;
    const serialized = try std.fmt.allocPrint(frame.local_arena, "{s} {s}", .{ alignment, meet_or_slice });
    try self._element.setAttributeSafe(String.wrap("preserveAspectRatio"), .wrap(serialized), frame);
}

fn alignName(value: u16) ?[]const u8 {
    return switch (value) {
        1 => "none",
        2 => "xMinYMin",
        3 => "xMidYMin",
        4 => "xMaxYMin",
        5 => "xMinYMid",
        6 => "xMidYMid",
        7 => "xMaxYMid",
        8 => "xMinYMax",
        9 => "xMidYMax",
        10 => "xMaxYMax",
        else => null,
    };
}

fn alignValue(value: []const u8) ?u16 {
    inline for (1..11) |i| {
        if (std.mem.eql(u8, value, alignName(i).?)) {
            return i;
        }
    }
    return null;
}

fn meetOrSliceName(value: u16) ?[]const u8 {
    return switch (value) {
        1 => "meet",
        2 => "slice",
        else => null,
    };
}

fn meetOrSliceValue(value: []const u8) ?u16 {
    if (std.mem.eql(u8, value, "meet")) {
        return 1;
    }
    if (std.mem.eql(u8, value, "slice")) {
        return 2;
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PreserveAspectRatio);

    pub const Meta = struct {
        pub const name = "SVGPreserveAspectRatio";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_PRESERVEASPECTRATIO_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_NONE = bridge.property(1, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMINYMIN = bridge.property(2, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMIDYMIN = bridge.property(3, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMAXYMIN = bridge.property(4, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMINYMID = bridge.property(5, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMIDYMID = bridge.property(6, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMAXYMID = bridge.property(7, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMINYMAX = bridge.property(8, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMIDYMAX = bridge.property(9, .{ .template = true });
    pub const SVG_PRESERVEASPECTRATIO_XMAXYMAX = bridge.property(10, .{ .template = true });
    pub const SVG_MEETORSLICE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_MEETORSLICE_MEET = bridge.property(1, .{ .template = true });
    pub const SVG_MEETORSLICE_SLICE = bridge.property(2, .{ .template = true });

    pub const @"align" = bridge.accessor(PreserveAspectRatio.getAlign, PreserveAspectRatio.setAlign, .{});
    pub const meetOrSlice = bridge.accessor(PreserveAspectRatio.getMeetOrSlice, PreserveAspectRatio.setMeetOrSlice, .{});
};
