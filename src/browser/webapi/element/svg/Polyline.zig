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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const GeometryElement = @import("GeometryElement.zig");
const DOMRect = @import("../../DOMRect.zig");
const String = @import("../../../../string.zig").String;

const Polyline = @This();
_proto: *GeometryElement,

pub fn asGraphics(self: *Polyline) *GraphicsElement {
    return self._proto._proto;
}
pub fn asSvg(self: *Polyline) *Svg {
    return self.asGraphics()._proto;
}
pub fn asElement(self: *Polyline) *Element {
    return self.asSvg()._proto;
}
pub fn asConstElement(self: *const Polyline) *const Element {
    return @as(*const GraphicsElement, self._proto._proto)._proto._proto;
}
pub fn asNode(self: *Polyline) *Node {
    return self.asElement().asNode();
}

pub fn get_points(self: *Polyline) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime String.wrap("points")) orelse "";
}

pub fn set_points(self: *Polyline, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime String.wrap("points"), String.wrap(value), page);
}

fn parsePointsBBox(data: []const u8) ?[4]f64 {
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    var found = false;
    var it = std.mem.tokenizeAny(u8, data, " ,\t\r\n");
    while (it.next()) |x_str| {
        const x = std.fmt.parseFloat(f64, x_str) catch {
            _ = it.next();
            continue;
        };
        const y_str = it.next() orelse break;
        const y = std.fmt.parseFloat(f64, y_str) catch continue;
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
        found = true;
    }
    if (!found) return null;
    return .{ min_x, min_y, max_x - min_x, max_y - min_y };
}

pub fn getBBox(self: *Polyline, page: *Page) !*DOMRect {
    const pts = self.asConstElement().getAttributeSafe(comptime String.wrap("points")) orelse
        return DOMRect.init(0, 0, 0, 0, page);
    const bbox = parsePointsBBox(pts) orelse return DOMRect.init(0, 0, 0, 0, page);
    return DOMRect.init(bbox[0], bbox[1], bbox[2], bbox[3], page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Polyline);
    pub const Meta = struct {
        pub const name = "SVGPolylineElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const getBBox = bridge.function(Polyline.getBBox, .{});
    pub const points = bridge.accessor(Polyline.get_points, Polyline.set_points, .{});
};
