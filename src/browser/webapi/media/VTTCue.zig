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

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const DocumentFragment = @import("../DocumentFragment.zig");

const cue_text = @import("cue_text.zig");
const VTTRegion = @import("VTTRegion.zig");
const TextTrackCue = @import("TextTrackCue.zig");

const VTTCue = @This();

pub const Proto = TextTrackCue;

_proto: *TextTrackCue,
_text: []const u8 = "",
_region: ?*VTTRegion = null,
_vertical: Direction = .horizontal,
_snap_to_lines: bool = true,
_line: ?f64 = null, // null represents "auto"
_line_align: LineAlign = .start,
_position: ?f64 = null, // null represents "auto"
_position_align: PositionAlign = .auto,
_size: f64 = 100,
_align: Align = .center,

pub const Direction = enum {
    horizontal,
    rl,
    lr,

    pub fn fromString(value: []const u8) ?Direction {
        if (value.len == 0) {
            return .horizontal;
        }
        return std.meta.stringToEnum(Direction, value) orelse return null;
    }
};

pub const LineAlign = enum { start, center, end };
pub const PositionAlign = enum { @"line-left", center, @"line-right", auto };
pub const Align = enum { start, center, end, left, right };

pub fn constructor(start_time: f64, end_time: f64, text: []const u8, frame: *Frame) !*VTTCue {
    if (std.math.isFinite(start_time) == false) {
        return error.TypeError;
    }
    if (std.math.isNan(end_time) or end_time == -std.math.inf(f64)) {
        return error.TypeError;
    }
    return init(start_time, end_time, try frame.dupeString(text), frame);
}

// `text` must already be owned by the page.
pub fn init(start_time: f64, end_time: f64, text: []const u8, frame: *Frame) !*VTTCue {
    const cue = try frame._factory.textTrackCue(VTTCue{
        ._proto = undefined,
        ._text = text,
    });

    cue._proto._start_time = start_time;
    cue._proto._end_time = end_time;

    return cue;
}

pub fn asCue(self: *VTTCue) *TextTrackCue {
    return self._proto;
}

pub fn getText(self: *const VTTCue) []const u8 {
    return self._text;
}

fn setText(self: *VTTCue, value: []const u8, frame: *Frame) !void {
    self._text = try frame.dupeString(value);
}

fn getRegion(self: *const VTTCue) ?*VTTRegion {
    return self._region;
}

fn setRegion(self: *VTTCue, value: ?*VTTRegion) void {
    self._region = value;
}

fn getVertical(self: *const VTTCue) []const u8 {
    return switch (self._vertical) {
        .horizontal => "",
        else => |v| @tagName(v),
    };
}

fn setVertical(self: *VTTCue, value: []const u8) void {
    // Invalid enum values are ignored
    self._vertical = Direction.fromString(value) orelse return;
}

fn getSnapToLines(self: *const VTTCue) bool {
    return self._snap_to_lines;
}

fn setSnapToLines(self: *VTTCue, value: bool) void {
    self._snap_to_lines = value;
}

const LineAndPositionSetting = union(enum) {
    number: f64,
    auto: []const u8,
};

fn getLine(self: *const VTTCue) LineAndPositionSetting {
    if (self._line) |num| {
        return .{ .number = num };
    }
    return .{ .auto = "auto" };
}

fn setLine(self: *VTTCue, value: LineAndPositionSetting) !void {
    switch (value) {
        .number => |num| {
            if (std.math.isFinite(num) == false) {
                return error.TypeError;
            }
            self._line = num;
        },
        .auto => |str| {
            if (std.mem.eql(u8, str, "auto") == false) {
                return error.TypeError;
            }
            self._line = null;
        },
    }
}

fn getLineAlign(self: *const VTTCue) []const u8 {
    return @tagName(self._line_align);
}

fn setLineAlign(self: *VTTCue, value: []const u8) void {
    self._line_align = std.meta.stringToEnum(LineAlign, value) orelse return;
}

fn getPosition(self: *const VTTCue) LineAndPositionSetting {
    if (self._position) |num| {
        return .{ .number = num };
    }
    return .{ .auto = "auto" };
}

fn setPosition(self: *VTTCue, value: LineAndPositionSetting) !void {
    switch (value) {
        .number => |num| {
            if (std.math.isFinite(num) == false) {
                return error.TypeError;
            }
            if (num < 0 or num > 100) {
                return error.IndexSizeError;
            }
            self._position = num;
        },
        .auto => |str| {
            if (std.mem.eql(u8, str, "auto") == false) {
                return error.TypeError;
            }
            self._position = null;
        },
    }
}

fn getPositionAlign(self: *const VTTCue) []const u8 {
    return @tagName(self._position_align);
}

fn setPositionAlign(self: *VTTCue, value: []const u8) void {
    self._position_align = std.meta.stringToEnum(PositionAlign, value) orelse return;
}

pub fn getSize(self: *const VTTCue) f64 {
    return self._size;
}

fn setSize(self: *VTTCue, value: f64) !void {
    if (std.math.isFinite(value) == false) {
        return error.TypeError;
    }
    if (value < 0 or value > 100) {
        return error.IndexSizeError;
    }
    self._size = value;
}

fn getAlign(self: *const VTTCue) []const u8 {
    return @tagName(self._align);
}

fn setAlign(self: *VTTCue, value: []const u8) void {
    self._align = std.meta.stringToEnum(Align, value) orelse return;
}

fn getCueAsHTML(self: *const VTTCue, frame: *Frame) !*DocumentFragment {
    return cue_text.toFragment(self._text, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VTTCue);

    pub const Meta = struct {
        pub const name = "VTTCue";

        pub var class_id: bridge.ClassId = undefined;
    };

    pub const Prototype = TextTrackCue;

    pub const constructor = bridge.constructor(VTTCue.constructor, .{});
    pub const text = bridge.accessor(VTTCue.getText, VTTCue.setText, .{});
    pub const region = bridge.accessor(VTTCue.getRegion, VTTCue.setRegion, .{});
    pub const vertical = bridge.accessor(VTTCue.getVertical, VTTCue.setVertical, .{});
    pub const snapToLines = bridge.accessor(VTTCue.getSnapToLines, VTTCue.setSnapToLines, .{});
    pub const line = bridge.accessor(VTTCue.getLine, VTTCue.setLine, .{});
    pub const lineAlign = bridge.accessor(VTTCue.getLineAlign, VTTCue.setLineAlign, .{});
    pub const position = bridge.accessor(VTTCue.getPosition, VTTCue.setPosition, .{});
    pub const positionAlign = bridge.accessor(VTTCue.getPositionAlign, VTTCue.setPositionAlign, .{});
    pub const size = bridge.accessor(VTTCue.getSize, VTTCue.setSize, .{});
    pub const @"align" = bridge.accessor(VTTCue.getAlign, VTTCue.setAlign, .{});
    pub const getCueAsHTML = bridge.function(VTTCue.getCueAsHTML, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: VTTCue" {
    try testing.htmlRunner("media/vttcue.html", .{});
}
