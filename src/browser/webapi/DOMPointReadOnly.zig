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

const DOMPointReadOnly = @This();

pub const _prototype_root = true;

_type: Type,
_rc: lp.RC,

_x: f64,
_y: f64,
_z: f64,
_w: f64,
_attachment: ?Attachment = null,

// Sticky. An animVal item that a later external attribute change detaches from
// its list must not turn into a writable orphan.
_read_only: bool = false,

// SVGPoint's coordinates are a restricted float: NaN and infinity are a
// TypeError rather than a stored value. Only points that reach an SVG list are
// restricted; a plain DOMPoint takes an unrestricted double.
_restricted: bool = false,

pub const Coordinate = enum { x, y, z, w };

pub const Attachment = struct {
    owner: *anyopaque,
    mutate: *const fn (*anyopaque, *DOMPointReadOnly, Coordinate, f64) anyerror!void,
};

pub const Type = union(enum) {
    generic,
    mutable: *DOMPoint,
};

pub const DOMPointInit = struct {
    w: f64 = 1,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
};

pub fn init(x_: ?f64, y_: ?f64, z_: ?f64, w_: ?f64, exec: *const js.Execution) !*DOMPointReadOnly {
    return createBare(x_ orelse 0, y_ orelse 0, z_ orelse 0, w_ orelse 1, exec.page);
}

pub fn deinit(self: *DOMPointReadOnly, page: *Page) void {
    switch (self._type) {
        .generic => page.factory.destroy(self),
        .mutable => |point| page.factory.destroy(point),
    }
}

pub fn acquireRef(self: *DOMPointReadOnly) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *DOMPointReadOnly, page: *Page) void {
    self._rc.release(self, page);
}

pub fn createBare(x: f64, y: f64, z: f64, w: f64, page: *Page) !*DOMPointReadOnly {
    return page.factory.create(buildValue(x, y, z, w));
}

pub fn buildValue(x: f64, y: f64, z: f64, w: f64) DOMPointReadOnly {
    return .{
        ._rc = .{},
        ._type = .generic,
        ._x = x,
        ._y = y,
        ._z = z,
        ._w = w,
    };
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

pub fn setCoordinate(self: *DOMPointReadOnly, coordinate: Coordinate, value: f64) !void {
    if (self._read_only) return error.NoModificationAllowed;
    if (self._restricted and !std.math.isFinite(value)) return error.TypeError;
    if (self._attachment) |attachment| {
        return attachment.mutate(attachment.owner, self, coordinate, value);
    }
    self.setCoordinateRaw(coordinate, value);
}

pub fn setCoordinateRaw(self: *DOMPointReadOnly, coordinate: Coordinate, value: f64) void {
    switch (coordinate) {
        .x => self._x = value,
        .y => self._y = value,
        .z => self._z = value,
        .w => self._w = value,
    }
}

pub fn restrict(self: *DOMPointReadOnly) void {
    self._restricted = true;
}

pub fn attach(self: *DOMPointReadOnly, attachment: Attachment, read_only: bool) void {
    self._attachment = attachment;
    if (read_only) self._read_only = true;
}

pub fn detach(self: *DOMPointReadOnly, owner: *anyopaque) void {
    const attachment = self._attachment orelse return;
    if (attachment.owner == owner) self._attachment = null;
}

pub fn isAttached(self: *const DOMPointReadOnly) bool {
    return self._attachment != null;
}

pub fn isAttachedTo(self: *const DOMPointReadOnly, owner: *anyopaque) bool {
    const attachment = self._attachment orelse return false;
    return attachment.owner == owner;
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
