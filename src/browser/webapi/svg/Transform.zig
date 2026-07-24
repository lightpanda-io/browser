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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const DOMMatrix = @import("../DOMMatrix.zig");
const RO = @import("../DOMMatrixReadOnly.zig");

const Transform = @This();

pub const DOMMatrix2DInit = struct {
    a: ?f64 = null,
    b: ?f64 = null,
    c: ?f64 = null,
    d: ?f64 = null,
    e: ?f64 = null,
    f: ?f64 = null,
    m11: ?f64 = null,
    m12: ?f64 = null,
    m21: ?f64 = null,
    m22: ?f64 = null,
    m41: ?f64 = null,
    m42: ?f64 = null,
};

_type: u16 = 1,
_angle: f64 = 0,
_cx: f64 = 0,
_cy: f64 = 0,
_matrix: *DOMMatrix,
_attachment: ?Attachment = null,

pub const State = struct {
    typ: u16,
    angle: f64,
    cx: f64,
    cy: f64,
    matrix: [16]f64,
    is_2d: bool,
};

pub const Attachment = struct {
    owner: *anyopaque,
    read_only: bool,
    mutate: *const fn (*anyopaque, *Transform, State) anyerror!void,
};

// The transform owns the matrix arena even when no JS wrapper currently
// references `matrix`. Forwarding the transform's bridge lifetime keeps the
// stable SameObject pointer valid across garbage collections.
pub fn acquireRef(self: *Transform) void {
    self._matrix._proto.acquireRef();
}

pub fn releaseRef(self: *Transform, page: *Page) void {
    self._matrix._proto.releaseRef(page);
}

pub fn detached(frame: *Frame) !*Transform {
    const matrix = try DOMMatrix.create(RO.identity(), true, frame._page);
    errdefer matrix._proto.deinit(frame._page);
    return frame._factory.create(Transform{ ._matrix = matrix });
}

pub fn fromMatrix(init: ?DOMMatrix2DInit, frame: *Frame) !*Transform {
    const parsed = try fixup2D(init orelse .{});
    const matrix = try DOMMatrix.create(parsed.m, true, frame._page);
    errdefer matrix._proto.deinit(frame._page);
    return frame._factory.create(Transform{ ._matrix = matrix });
}

pub fn fromParsed(parsed: RO.ParsedTransform, frame: *Frame) !*Transform {
    const typ: u16 = switch (parsed.kind) {
        .matrix => 1,
        .translate => 2,
        .scale => 3,
        .rotate => 4,
        .skew_x => 5,
        .skew_y => 6,
        else => return error.SyntaxError,
    };
    const matrix = try DOMMatrix.create(parsed.matrix, parsed.is_2d, frame._page);
    errdefer matrix._proto.deinit(frame._page);
    return frame._factory.create(Transform{
        ._type = typ,
        ._angle = if (typ >= 4) parsed.values[0] else 0,
        ._cx = if (typ == 4 and parsed.count == 3) parsed.values[1] else 0,
        ._cy = if (typ == 4 and parsed.count == 3) parsed.values[2] else 0,
        ._matrix = matrix,
    });
}

pub fn clone(self: *const Transform, frame: *Frame) !*Transform {
    const current = self.getState();
    const matrix = try DOMMatrix.create(current.matrix, current.is_2d, frame._page);
    errdefer matrix._proto.deinit(frame._page);
    return frame._factory.create(Transform{
        ._type = current.typ,
        ._angle = current.angle,
        ._cx = current.cx,
        ._cy = current.cy,
        ._matrix = matrix,
    });
}

pub fn getType(self: *const Transform) u16 {
    return self._type;
}

pub fn getMatrix(self: *Transform) *DOMMatrix {
    return self._matrix;
}

pub fn getAngle(self: *const Transform) f64 {
    return self._angle;
}

pub fn setMatrix(self: *Transform, init: ?DOMMatrix2DInit) !void {
    const parsed = try fixup2D(init orelse .{});
    try self.applyState(.{ .typ = 1, .angle = 0, .cx = 0, .cy = 0, .matrix = parsed.m, .is_2d = true });
}

pub fn setTranslate(self: *Transform, tx: f64, ty: f64) !void {
    try ensureFinite(&.{ tx, ty });
    try self.applyState(.{ .typ = 2, .angle = 0, .cx = 0, .cy = 0, .matrix = RO.translationMatrix(tx, ty, 0), .is_2d = true });
}

pub fn setScale(self: *Transform, sx: f64, sy: f64) !void {
    try ensureFinite(&.{ sx, sy });
    try self.applyState(.{ .typ = 3, .angle = 0, .cx = 0, .cy = 0, .matrix = RO.scaleMatrix(sx, sy, 1), .is_2d = true });
}

pub fn setRotate(self: *Transform, angle: f64, cx: f64, cy: f64) !void {
    try ensureFinite(&.{ angle, cx, cy });
    const radians = angle * std.math.pi / 180.0;
    var matrix = RO.translationMatrix(cx, cy, 0);
    matrix = RO.multiplyMatrix(matrix, RO.rotateZMatrix(radians));
    matrix = RO.multiplyMatrix(matrix, RO.translationMatrix(-cx, -cy, 0));
    try self.applyState(.{ .typ = 4, .angle = angle, .cx = cx, .cy = cy, .matrix = matrix, .is_2d = true });
}

pub fn setSkewX(self: *Transform, angle: f64) !void {
    try ensureFinite(&.{angle});
    try self.applyState(.{ .typ = 5, .angle = angle, .cx = 0, .cy = 0, .matrix = RO.skewMatrix(angle * std.math.pi / 180.0, 0), .is_2d = true });
}

pub fn setSkewY(self: *Transform, angle: f64) !void {
    try ensureFinite(&.{angle});
    try self.applyState(.{ .typ = 6, .angle = angle, .cx = 0, .cy = 0, .matrix = RO.skewMatrix(0, angle * std.math.pi / 180.0), .is_2d = true });
}

pub fn getState(self: *const Transform) State {
    return .{
        .typ = self._type,
        .angle = self._angle,
        .cx = self._cx,
        .cy = self._cy,
        .matrix = self._matrix._proto._m,
        .is_2d = self._matrix._proto._is_2d,
    };
}

pub fn applyStateRaw(self: *Transform, state: State) void {
    self._type = state.typ;
    self._angle = state.angle;
    self._cx = state.cx;
    self._cy = state.cy;
    self._matrix._proto._m = state.matrix;
    self._matrix._proto._is_2d = state.is_2d;
}

fn applyState(self: *Transform, state: State) !void {
    try ensureFinite(&state.matrix);
    if (self._attachment) |attachment| {
        if (attachment.read_only) return error.NoModificationAllowed;
        return attachment.mutate(attachment.owner, self, state);
    }
    self.applyStateRaw(state);
}

pub fn attach(self: *Transform, attachment: Attachment) void {
    self._attachment = attachment;
}

pub fn detach(self: *Transform, owner: *anyopaque) void {
    const attachment = self._attachment orelse return;
    if (attachment.owner == owner) self._attachment = null;
}

pub fn isAttached(self: *const Transform) bool {
    return self._attachment != null;
}

pub fn isAttachedTo(self: *const Transform, owner: *anyopaque) bool {
    const attachment = self._attachment orelse return false;
    return attachment.owner == owner;
}

pub fn writeState(state: State, writer: anytype) !void {
    switch (state.typ) {
        1 => try writer.print("matrix({d} {d} {d} {d} {d} {d})", .{
            state.matrix[0], state.matrix[1], state.matrix[4], state.matrix[5], state.matrix[12], state.matrix[13],
        }),
        2 => try writer.print("translate({d} {d})", .{ state.matrix[12], state.matrix[13] }),
        3 => try writer.print("scale({d} {d})", .{ state.matrix[0], state.matrix[5] }),
        4 => if (state.cx == 0 and state.cy == 0)
            try writer.print("rotate({d})", .{state.angle})
        else
            try writer.print("rotate({d} {d} {d})", .{ state.angle, state.cx, state.cy }),
        5 => try writer.print("skewX({d})", .{state.angle}),
        6 => try writer.print("skewY({d})", .{state.angle}),
        else => return error.SyntaxError,
    }
}

fn fixup2D(init: DOMMatrix2DInit) !RO.Parsed {
    const parsed = try RO.fixupDict(.{
        .a = init.a,
        .b = init.b,
        .c = init.c,
        .d = init.d,
        .e = init.e,
        .f = init.f,
        .m11 = init.m11,
        .m12 = init.m12,
        .m21 = init.m21,
        .m22 = init.m22,
        .m41 = init.m41,
        .m42 = init.m42,
        .is2D = true,
    });
    try ensureFinite(&parsed.m);
    return parsed;
}

fn ensureFinite(values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.TypeError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Transform);

    pub const Meta = struct {
        pub const name = "SVGTransform";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_TRANSFORM_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_TRANSFORM_MATRIX = bridge.property(1, .{ .template = true });
    pub const SVG_TRANSFORM_TRANSLATE = bridge.property(2, .{ .template = true });
    pub const SVG_TRANSFORM_SCALE = bridge.property(3, .{ .template = true });
    pub const SVG_TRANSFORM_ROTATE = bridge.property(4, .{ .template = true });
    pub const SVG_TRANSFORM_SKEWX = bridge.property(5, .{ .template = true });
    pub const SVG_TRANSFORM_SKEWY = bridge.property(6, .{ .template = true });

    pub const @"type" = bridge.accessor(Transform.getType, null, .{});
    pub const matrix = bridge.accessor(Transform.getMatrix, null, .{});
    pub const angle = bridge.accessor(Transform.getAngle, null, .{});
    pub const setMatrix = bridge.function(Transform.setMatrix, .{});
    pub const setTranslate = bridge.function(Transform.setTranslate, .{});
    pub const setScale = bridge.function(Transform.setScale, .{});
    pub const setRotate = bridge.function(Transform.setRotate, .{});
    pub const setSkewX = bridge.function(Transform.setSkewX, .{});
    pub const setSkewY = bridge.function(Transform.setSkewY, .{});
};
