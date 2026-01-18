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

const Page = @import("../../Page.zig");
const TextTrackCue = @import("TextTrackCue.zig");

const VTTCue = @This();

_proto: *TextTrackCue,
_text: []const u8 = "",
_region: ?js.Object.Global = null,
_vertical: []const u8 = "",
_snap_to_lines: bool = true,
_line: ?f64 = null, // null represents "auto"
_position: ?f64 = null, // null represents "auto"
_size: f64 = 100,
_align: []const u8 = "center",

pub fn constructor(start_time: f64, end_time: f64, text: []const u8, page: *Page) !*VTTCue {
    const cue = try page._factory.textTrackCue(VTTCue{
        ._proto = undefined,
        ._text = try page.dupeString(text),
        ._region = null,
        ._vertical = "",
        ._snap_to_lines = true,
        ._line = null, // "auto"
        ._position = null, // "auto"
        ._size = 100,
        ._align = "center",
    });

    cue._proto._start_time = start_time;
    cue._proto._end_time = end_time;

    return cue;
}

pub fn asTextTrackCue(self: *VTTCue) *TextTrackCue {
    return self._proto;
}

pub fn getText(self: *const VTTCue) []const u8 {
    return self._text;
}

pub fn setText(self: *VTTCue, value: []const u8, page: *Page) !void {
    self._text = try page.dupeString(value);
}

pub fn getRegion(self: *const VTTCue) ?js.Object.Global {
    return self._region;
}

pub fn setRegion(self: *VTTCue, value: ?js.Object.Global) !void {
    self._region = value;
}

pub fn getVertical(self: *const VTTCue) []const u8 {
    return self._vertical;
}

pub fn setVertical(self: *VTTCue, value: []const u8, page: *Page) !void {
    // Valid values: "", "rl", "lr"
    self._vertical = try page.dupeString(value);
}

pub fn getSnapToLines(self: *const VTTCue) bool {
    return self._snap_to_lines;
}

pub fn setSnapToLines(self: *VTTCue, value: bool) void {
    self._snap_to_lines = value;
}

pub const LineAndPositionSetting = union(enum) {
    number: f64,
    auto: []const u8,
};

pub fn getLine(self: *const VTTCue) LineAndPositionSetting {
    if (self._line) |num| {
        return .{ .number = num };
    }
    return .{ .auto = "auto" };
}

pub fn setLine(self: *VTTCue, value: LineAndPositionSetting) void {
    switch (value) {
        .number => |num| self._line = num,
        .auto => self._line = null,
    }
}

pub fn getPosition(self: *const VTTCue) LineAndPositionSetting {
    if (self._position) |num| {
        return .{ .number = num };
    }
    return .{ .auto = "auto" };
}

pub fn setPosition(self: *VTTCue, value: LineAndPositionSetting) void {
    switch (value) {
        .number => |num| self._position = num,
        .auto => self._position = null,
    }
}

pub fn getSize(self: *const VTTCue) f64 {
    return self._size;
}

pub fn setSize(self: *VTTCue, value: f64) void {
    self._size = value;
}

pub fn getAlign(self: *const VTTCue) []const u8 {
    return self._align;
}

pub fn setAlign(self: *VTTCue, value: []const u8, page: *Page) !void {
    // Valid values: "start", "center", "end", "left", "right"
    self._align = try page.dupeString(value);
}

pub fn getCueAsHTML(self: *const VTTCue, page: *Page) !js.Object {
    // Minimal implementation: return a document fragment
    // In a full implementation, this would parse the VTT text into HTML nodes
    _ = self;
    _ = page;
    return error.NotImplemented;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VTTCue);

    pub const Meta = struct {
        pub const name = "VTTCue";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const Prototype = TextTrackCue;

    pub const constructor = bridge.constructor(VTTCue.constructor, .{});
    pub const text = bridge.accessor(VTTCue.getText, VTTCue.setText, .{});
    pub const region = bridge.accessor(VTTCue.getRegion, VTTCue.setRegion, .{});
    pub const vertical = bridge.accessor(VTTCue.getVertical, VTTCue.setVertical, .{});
    pub const snapToLines = bridge.accessor(VTTCue.getSnapToLines, VTTCue.setSnapToLines, .{});
    pub const line = bridge.accessor(VTTCue.getLine, VTTCue.setLine, .{});
    pub const position = bridge.accessor(VTTCue.getPosition, VTTCue.setPosition, .{});
    pub const size = bridge.accessor(VTTCue.getSize, VTTCue.setSize, .{});
    pub const @"align" = bridge.accessor(VTTCue.getAlign, VTTCue.setAlign, .{});
    pub const getCueAsHTML = bridge.function(VTTCue.getCueAsHTML, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: VTTCue" {
    try testing.htmlRunner("media/vttcue.html", .{});
}
