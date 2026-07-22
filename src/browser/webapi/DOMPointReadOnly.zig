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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const DOMPoint = @import("DOMPoint.zig");
const Matrix = @import("DOMMatrixReadOnly.zig");

const Allocator = std.mem.Allocator;

const DOMPointReadOnly = @This();

pub const _prototype_root = true;

_type: Type,
_rc: lp.RC,
_arena: Allocator,

_x: f64,
_y: f64,
_z: f64,
_w: f64,

pub const Type = union(enum) {
    generic,
    mutable: *DOMPoint,
};

pub const DOMPointInit = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    w: f64 = 1,
};

pub fn init(x_: ?f64, y_: ?f64, z_: ?f64, w_: ?f64, exec: *const js.Execution) !*DOMPointReadOnly {
    return createBare(x_ orelse 0, y_ orelse 0, z_ orelse 0, w_ orelse 1, exec.page);
}

pub fn deinit(self: *DOMPointReadOnly, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *DOMPointReadOnly) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *DOMPointReadOnly, page: *Page) void {
    self._rc.release(self, page);
}

pub fn createBare(x: f64, y: f64, z: f64, w: f64, page: *Page) !*DOMPointReadOnly {
    const arena = try page.getArena(.tiny, "DOMPoint");
    errdefer page.releaseArena(arena);

    const self = try arena.create(DOMPointReadOnly);
    self.* = .{
        ._rc = .{},
        ._arena = arena,
        ._type = .generic,
        ._x = x,
        ._y = y,
        ._z = z,
        ._w = w,
    };
    return self;
}

pub fn fromPoint(other_: ?DOMPointInit, page: *Page) !*DOMPointReadOnly {
    const other: DOMPointInit = other_ orelse .{};
    return createBare(other.x, other.y, other.z, other.w, page);
}

pub fn structuredSerialize(self: *const DOMPointReadOnly, writer: *js.StructuredWriter) !void {
    writer.writeUint64(@bitCast(self._x));
    writer.writeUint64(@bitCast(self._y));
    writer.writeUint64(@bitCast(self._z));
    writer.writeUint64(@bitCast(self._w));
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*DOMPointReadOnly {
    const x: f64 = @bitCast(try reader.readUint64());
    const y: f64 = @bitCast(try reader.readUint64());
    const z: f64 = @bitCast(try reader.readUint64());
    const w: f64 = @bitCast(try reader.readUint64());
    return createBare(x, y, z, w, page);
}

pub fn matrixTransform(self: *const DOMPointReadOnly, matrix_: ?Matrix.DOMMatrixInit, page: *Page) !*DOMPoint {
    const m = (try Matrix.fixupDict(matrix_ orelse .{})).m;
    const x = self._x;
    const y = self._y;
    const z = self._z;
    const w = self._w;
    return DOMPoint.create(
        m[0] * x + m[4] * y + m[8] * z + m[12] * w,
        m[1] * x + m[5] * y + m[9] * z + m[13] * w,
        m[2] * x + m[6] * y + m[10] * z + m[14] * w,
        m[3] * x + m[7] * y + m[11] * z + m[15] * w,
        page,
    );
}

pub fn getX(self: *const DOMPointReadOnly) f64 {
    return self._x;
}
pub fn getY(self: *const DOMPointReadOnly) f64 {
    return self._y;
}
pub fn getZ(self: *const DOMPointReadOnly) f64 {
    return self._z;
}
pub fn getW(self: *const DOMPointReadOnly) f64 {
    return self._w;
}

pub fn toJSON(self: *const DOMPointReadOnly) struct {
    x: f64,
    y: f64,
    z: f64,
    w: f64,
} {
    return .{ .x = self._x, .y = self._y, .z = self._z, .w = self._w };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMPointReadOnly);

    pub const Meta = struct {
        pub const name = "DOMPointReadOnly";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMPointReadOnly.init, .{});
    pub const fromPoint = bridge.function(DOMPointReadOnly.fromPoint, .{ .static = true });
    pub const x = bridge.accessor(DOMPointReadOnly.getX, null, .{});
    pub const y = bridge.accessor(DOMPointReadOnly.getY, null, .{});
    pub const z = bridge.accessor(DOMPointReadOnly.getZ, null, .{});
    pub const w = bridge.accessor(DOMPointReadOnly.getW, null, .{});

    pub const matrixTransform = bridge.function(DOMPointReadOnly.matrixTransform, .{});
    pub const toJSON = bridge.function(DOMPointReadOnly.toJSON, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMPoint" {
    try testing.htmlRunner("dompoint.html", .{});
}
