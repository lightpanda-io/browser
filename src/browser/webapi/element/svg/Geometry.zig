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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const DOMPoint = @import("../../DOMPoint.zig");

const Graphics = @import("Graphics.zig");
const AnimatedNumber = @import("../../svg/AnimatedNumber.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const PathData = @import("../../svg/PathData.zig");
pub const Rect = @import("Rect.zig");
pub const Circle = @import("Circle.zig");
pub const Ellipse = @import("Ellipse.zig");
pub const Line = @import("Line.zig");
pub const Path = @import("Path.zig");
pub const Polygon = @import("Polygon.zig");
pub const Polyline = @import("Polyline.zig");

const Geometry = @This();
_proto: *Graphics,
_type: Type,

pub const Type = union(enum) {
    rect: *Rect,
    circle: *Circle,
    ellipse: *Ellipse,
    line: *Line,
    path: *Path,
    polygon: *Polygon,
    polyline: *Polyline,
};

pub fn is(self: *Geometry, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    return null;
}

pub fn asElement(self: *Geometry) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Geometry) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Geometry);

    pub const Meta = struct {
        pub const name = "SVGGeometryElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const pathLength = bridge.accessor(Geometry.getPathLength, null, .{});
    pub const getTotalLength = bridge.function(Geometry.getTotalLength, .{});
    pub const getPointAtLength = bridge.function(Geometry.getPointAtLength, .{});
};

pub fn getPathLength(self: *Geometry, frame: *Frame) !*AnimatedNumber {
    return AnimatedNumber.getOrCreate(self.asElement(), frame);
}

pub fn getTotalLength(self: *Geometry, frame: *Frame) !f64 {
    var path = try self.buildPath(frame);
    defer path.deinit(frame.local_arena);
    return path.totalLength(frame.local_arena);
}

pub fn getPointAtLength(self: *Geometry, distance: f64, frame: *Frame) !*DOMPoint {
    if (!std.math.isFinite(distance)) return error.TypeError;
    var path = try self.buildPath(frame);
    defer path.deinit(frame.local_arena);
    const point = try path.pointAtLength(distance, frame.local_arena);
    return DOMPoint.create(point.x, point.y, 0, 1, frame._page);
}

pub fn buildPath(self: *Geometry, frame: *Frame) !PathData.Path {
    return switch (self._type) {
        .rect => |rect| buildRect(rect, frame),
        .circle => |circle| buildCircle(circle, frame),
        .ellipse => |ellipse| buildEllipse(ellipse, frame),
        .line => |line| buildLine(line, frame),
        .path => |path| PathData.parse(
            path.asElement().getAttributeSafe(comptime .wrap("d")) orelse "",
            frame.local_arena,
        ),
        .polygon => |polygon| buildPoints(try polygon.getPoints(frame), true, frame),
        .polyline => |polyline| buildPoints(try polyline.getPoints(frame), false, frame),
    };
}

fn value(length: *AnimatedLength, frame: *Frame) ?f64 {
    const base = length.getBaseVal();
    if (base.getUnitType() == 0) return null;
    const result = base.getValue(frame);
    return if (std.math.isFinite(result)) result else null;
}

fn buildRect(rect: *Rect, frame: *Frame) !PathData.Path {
    var path: PathData.Path = .{};
    errdefer path.deinit(frame.local_arena);

    const x = value(try rect.getX(frame), frame) orelse 0;
    const y = value(try rect.getY(frame), frame) orelse 0;
    const width = value(try rect.getWidth(frame), frame) orelse 0;
    const height = value(try rect.getHeight(frame), frame) orelse 0;
    if (width <= 0 or height <= 0) return path;

    const rx_value = optionalRadius(rect.asElement(), "rx", try rect.getRx(frame), frame);
    const ry_value = optionalRadius(rect.asElement(), "ry", try rect.getRy(frame), frame);
    var rx = rx_value orelse ry_value orelse 0;
    var ry = ry_value orelse rx_value orelse 0;
    rx = @min(rx, width / 2.0);
    ry = @min(ry, height / 2.0);

    const top_left = PathData.Point{ .x = x, .y = y };
    if (rx == 0 or ry == 0) {
        const top_right = PathData.Point{ .x = x + width, .y = y };
        const bottom_right = PathData.Point{ .x = x + width, .y = y + height };
        const bottom_left = PathData.Point{ .x = x, .y = y + height };
        try path.appendLine(top_left, top_right, frame.local_arena);
        try path.appendLine(top_right, bottom_right, frame.local_arena);
        try path.appendLine(bottom_right, bottom_left, frame.local_arena);
        try path.appendLine(bottom_left, top_left, frame.local_arena);
        return path;
    }

    const start = PathData.Point{ .x = x + rx, .y = y };
    const top_end = PathData.Point{ .x = x + width - rx, .y = y };
    const right_start = PathData.Point{ .x = x + width, .y = y + ry };
    const right_end = PathData.Point{ .x = x + width, .y = y + height - ry };
    const bottom_start = PathData.Point{ .x = x + width - rx, .y = y + height };
    const bottom_end = PathData.Point{ .x = x + rx, .y = y + height };
    const left_start = PathData.Point{ .x = x, .y = y + height - ry };
    const left_end = PathData.Point{ .x = x, .y = y + ry };

    try path.appendLine(start, top_end, frame.local_arena);
    try path.appendArc(top_end, rx, ry, 0, false, true, right_start, frame.local_arena);
    try path.appendLine(right_start, right_end, frame.local_arena);
    try path.appendArc(right_end, rx, ry, 0, false, true, bottom_start, frame.local_arena);
    try path.appendLine(bottom_start, bottom_end, frame.local_arena);
    try path.appendArc(bottom_end, rx, ry, 0, false, true, left_start, frame.local_arena);
    try path.appendLine(left_start, left_end, frame.local_arena);
    try path.appendArc(left_end, rx, ry, 0, false, true, start, frame.local_arena);
    return path;
}

fn optionalRadius(element: *Element, comptime name: []const u8, length: *AnimatedLength, frame: *Frame) ?f64 {
    const raw = element.getAttributeSafe(comptime .wrap(name)) orelse return null;
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n\x0c"), "auto")) return null;
    const result = value(length, frame) orelse return null;
    return if (result < 0) null else result;
}

fn buildCircle(circle: *Circle, frame: *Frame) !PathData.Path {
    const center = PathData.Point{
        .x = value(try circle.getCx(frame), frame) orelse 0,
        .y = value(try circle.getCy(frame), frame) orelse 0,
    };
    const radius = value(try circle.getR(frame), frame) orelse 0;
    return buildEllipsePath(center, radius, radius, frame);
}

fn buildEllipse(ellipse: *Ellipse, frame: *Frame) !PathData.Path {
    const center = PathData.Point{
        .x = value(try ellipse.getCx(frame), frame) orelse 0,
        .y = value(try ellipse.getCy(frame), frame) orelse 0,
    };
    const rx = optionalRadius(ellipse.asElement(), "rx", try ellipse.getRx(frame), frame);
    const ry = optionalRadius(ellipse.asElement(), "ry", try ellipse.getRy(frame), frame);
    return buildEllipsePath(center, rx orelse ry orelse 0, ry orelse rx orelse 0, frame);
}

fn buildEllipsePath(center: PathData.Point, rx: f64, ry: f64, frame: *Frame) !PathData.Path {
    var path: PathData.Path = .{};
    errdefer path.deinit(frame.local_arena);
    if (rx <= 0 or ry <= 0) return path;

    const right = PathData.Point{ .x = center.x + rx, .y = center.y };
    const bottom = PathData.Point{ .x = center.x, .y = center.y + ry };
    const left = PathData.Point{ .x = center.x - rx, .y = center.y };
    const top = PathData.Point{ .x = center.x, .y = center.y - ry };
    try path.appendArc(right, rx, ry, 0, false, true, bottom, frame.local_arena);
    try path.appendArc(bottom, rx, ry, 0, false, true, left, frame.local_arena);
    try path.appendArc(left, rx, ry, 0, false, true, top, frame.local_arena);
    try path.appendArc(top, rx, ry, 0, false, true, right, frame.local_arena);
    return path;
}

fn buildLine(line: *Line, frame: *Frame) !PathData.Path {
    var path: PathData.Path = .{};
    errdefer path.deinit(frame.local_arena);
    const start = PathData.Point{
        .x = value(try line.getX1(frame), frame) orelse 0,
        .y = value(try line.getY1(frame), frame) orelse 0,
    };
    const end = PathData.Point{
        .x = value(try line.getX2(frame), frame) orelse 0,
        .y = value(try line.getY2(frame), frame) orelse 0,
    };
    try path.appendLine(start, end, frame.local_arena);
    return path;
}

fn buildPoints(list: anytype, close: bool, frame: *Frame) !PathData.Path {
    var path: PathData.Path = .{};
    errdefer path.deinit(frame.local_arena);
    const count = try list.getNumberOfItems(frame);
    if (count == 0) return path;

    const first_item = try list.getItem(0, frame);
    const first = PathData.Point{ .x = first_item.getX(), .y = first_item.getY() };
    path.first_point = first;
    var previous = first;
    for (1..count) |index| {
        const item = try list.getItem(@intCast(index), frame);
        const next = PathData.Point{ .x = item.getX(), .y = item.getY() };
        try path.appendLine(previous, next, frame.local_arena);
        previous = next;
    }
    if (close and count > 1) try path.appendLine(previous, first, frame.local_arena);
    return path;
}
