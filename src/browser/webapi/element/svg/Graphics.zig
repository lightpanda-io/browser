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
const DOMRect = @import("../../DOMRect.zig");
const DOMMatrixReadOnly = @import("../../DOMMatrixReadOnly.zig");
const SvgElement = @import("../Svg.zig");
const AnimatedTransformList = @import("../../svg/AnimatedTransformList.zig");
const PathData = @import("../../svg/PathData.zig");
const StringList = @import("../../svg/StringList.zig");

pub const Svg = @import("Svg.zig");
pub const G = @import("G.zig");
pub const A = @import("A.zig");
pub const Use = @import("Use.zig");
pub const Image = @import("Image.zig");
pub const Defs = @import("Defs.zig");
pub const Symbol = @import("Symbol.zig");
pub const Switch = @import("Switch.zig");
pub const ForeignObject = @import("ForeignObject.zig");
pub const Geometry = @import("Geometry.zig");

const Graphics = @This();
_proto: *SvgElement,
_type: Type,
_required_extensions: ?*StringList = null,
_system_language: ?*StringList = null,

pub const Type = union(enum) {
    svg: *Svg,
    g: *G,
    a: *A,
    use: *Use,
    image: *Image,
    defs: *Defs,
    symbol: *Symbol,
    switch_element: *Switch,
    foreign_object: *ForeignObject,
    geometry: *Geometry,
};

pub fn is(self: *Graphics, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    if (self._type == .geometry) {
        return self._type.geometry.is(T);
    }
    return null;
}

pub fn asElement(self: *Graphics) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Graphics) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Graphics);

    pub const Meta = struct {
        pub const name = "SVGGraphicsElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const transform = bridge.accessor(Graphics.getTransform, null, .{});
    pub const requiredExtensions = bridge.accessor(Graphics.getRequiredExtensions, null, .{});
    pub const systemLanguage = bridge.accessor(Graphics.getSystemLanguage, null, .{});
    pub const getBBox = bridge.function(Graphics.getBBox, .{});
};

const BoundingBoxOptions = struct {
    fill: bool = true,
    stroke: bool = false,
    markers: bool = false,
    clipped: bool = false,
};

pub fn getBBox(self: *Graphics, options_: ?BoundingBoxOptions, frame: *Frame) !*DOMRect {
    const options = options_ orelse BoundingBoxOptions{};
    if (options.stroke or options.markers or options.clipped) return error.NotSupported;
    if (!options.fill) return DOMRect.create(.{}, frame._factory);

    var bounds: PathData.Bounds = .{};
    switch (self._type) {
        .geometry => |geometry| {
            var path = try geometry.buildPath(frame);
            defer path.deinit(frame.local_arena);
            bounds = path.bounds(.{});
        },
        .foreign_object => |foreign_object| bounds = try foreign_object.getBounds(frame),
        .g, .a, .svg => try accumulateChildren(self, .{}, &bounds, frame),
        .defs, .symbol, .switch_element, .use, .image => return error.InvalidStateError,
    }
    if (bounds.isEmpty()) return DOMRect.create(.{}, frame._factory);
    return DOMRect.create(.{
        .x = bounds.min_x,
        .y = bounds.min_y,
        .width = bounds.width(),
        .height = bounds.height(),
    }, frame._factory);
}

fn accumulateChildren(parent: *Graphics, matrix: PathData.Matrix, bounds: *PathData.Bounds, frame: *Frame) !void {
    const Cursor = struct {
        next: ?*Node,
        matrix: PathData.Matrix,
    };
    var cursors: std.ArrayList(Cursor) = .empty;
    try cursors.append(frame.local_arena, .{
        .next = parent.asNode().firstChild(),
        .matrix = matrix,
    });

    while (cursors.items.len != 0) {
        const cursor = &cursors.items[cursors.items.len - 1];
        const node = cursor.next orelse {
            _ = cursors.pop();
            continue;
        };
        cursor.next = node.nextSibling();
        const parent_matrix = cursor.matrix;

        const element = node.is(Element) orelse continue;
        if (element._namespace != .svg) continue;
        const svg = element.as(SvgElement);
        const graphics = svg.is(Graphics) orelse continue;
        const child_matrix = parent_matrix.multiply(transformMatrix(element));

        switch (graphics._type) {
            .geometry => |geometry| {
                var path = try geometry.buildPath(frame);
                defer path.deinit(frame.local_arena);
                bounds.merge(path.bounds(child_matrix));
            },
            .foreign_object => |foreign_object| {
                const child_bounds = try foreign_object.getBounds(frame);
                if (!child_bounds.isEmpty()) {
                    var foreign_path: PathData.Path = .{};
                    defer foreign_path.deinit(frame.local_arena);
                    const top_left = PathData.Point{ .x = child_bounds.min_x, .y = child_bounds.min_y };
                    const top_right = PathData.Point{ .x = child_bounds.max_x, .y = child_bounds.min_y };
                    const bottom_right = PathData.Point{ .x = child_bounds.max_x, .y = child_bounds.max_y };
                    const bottom_left = PathData.Point{ .x = child_bounds.min_x, .y = child_bounds.max_y };
                    try foreign_path.appendLine(top_left, top_right, frame.local_arena);
                    try foreign_path.appendLine(top_right, bottom_right, frame.local_arena);
                    try foreign_path.appendLine(bottom_right, bottom_left, frame.local_arena);
                    try foreign_path.appendLine(bottom_left, top_left, frame.local_arena);
                    bounds.merge(foreign_path.bounds(child_matrix));
                }
            },
            .g, .a => try cursors.append(frame.local_arena, .{
                .next = graphics.asNode().firstChild(),
                .matrix = child_matrix,
            }),
            .defs, .symbol => {},
            .svg, .switch_element, .use, .image => return error.InvalidStateError,
        }
    }
}

fn transformMatrix(element: *Element) PathData.Matrix {
    const raw = element.getAttributeSafe(comptime .wrap("transform")) orelse return .{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) return .{};

    var matrix = DOMMatrixReadOnly.identity();
    var iterator = DOMMatrixReadOnly.TransformFunctionIterator{ .input = trimmed, .allow_comma = true };
    while (iterator.next() catch return .{}) |function| {
        const parsed = DOMMatrixReadOnly.parseTransformFunction(function, .svg) catch return .{};
        matrix = DOMMatrixReadOnly.multiplyMatrix(matrix, parsed.matrix);
    }
    return .{
        .a = matrix[0],
        .b = matrix[1],
        .c = matrix[4],
        .d = matrix[5],
        .e = matrix[12],
        .f = matrix[13],
    };
}

pub fn getTransform(self: *Graphics, frame: *Frame) !*AnimatedTransformList {
    return AnimatedTransformList.getOrCreate(self.asElement(), .transform, frame);
}

pub fn getRequiredExtensions(self: *Graphics, frame: *Frame) !*StringList {
    if (self._required_extensions == null) {
        self._required_extensions = try StringList.create(
            self.asElement(),
            .wrap("requiredExtensions"),
            .whitespace,
            frame,
        );
    }
    return self._required_extensions.?;
}

pub fn getSystemLanguage(self: *Graphics, frame: *Frame) !*StringList {
    if (self._system_language == null) {
        self._system_language = try StringList.create(
            self.asElement(),
            .wrap("systemLanguage"),
            .comma,
            frame,
        );
    }
    return self._system_language.?;
}
