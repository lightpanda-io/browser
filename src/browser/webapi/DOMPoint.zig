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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const RO = @import("DOMPointReadOnly.zig");

const DOMPoint = @This();

_proto: *RO,

pub fn init(x_: ?f64, y_: ?f64, z_: ?f64, w_: ?f64, exec: *const js.Execution) !*DOMPoint {
    return create(x_ orelse 0, y_ orelse 0, z_ orelse 0, w_ orelse 1, exec.page);
}

pub fn create(x: f64, y: f64, z: f64, w: f64, page: *Page) !*DOMPoint {
    const proto = try RO.createBare(x, y, z, w, page);
    errdefer proto.deinit(page);

    const self = try proto._arena.create(DOMPoint);
    self.* = .{ ._proto = proto };
    proto._type = .{ .mutable = self };
    return self;
}

pub fn fromPoint(other_: ?RO.DOMPointInit, page: *Page) !*DOMPoint {
    const other: RO.DOMPointInit = other_ orelse .{};
    return create(other.x, other.y, other.z, other.w, page);
}

pub fn structuredSerialize(self: *const DOMPoint, writer: *js.StructuredWriter) !void {
    try self._proto.structuredSerialize(writer);
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*DOMPoint {
    const proto = try RO.structuredDeserialize(reader, page);
    errdefer proto.deinit(page);

    const self = try proto._arena.create(DOMPoint);
    self.* = .{ ._proto = proto };
    proto._type = .{ .mutable = self };
    return self;
}

// DOMPoint redeclares x/y/z/w as writable (`inherit attribute` in the IDL), so
// DOMPoint.prototype needs its own read-write accessors, distinct from the
// read-only ones on DOMPointReadOnly.prototype. The setters are the point; each
// accessor bundles a getter too, so we pair them with DOMPoint-typed getters
// that read through `_proto` (they could reuse the base getters — the receiver
// unwraps down the prototype chain either way — but keeping the pair symmetric
// mirrors DOMMatrix).
pub fn getX(self: *const DOMPoint) f64 {
    return self._proto._x;
}
pub fn getY(self: *const DOMPoint) f64 {
    return self._proto._y;
}
pub fn getZ(self: *const DOMPoint) f64 {
    return self._proto._z;
}
pub fn getW(self: *const DOMPoint) f64 {
    return self._proto._w;
}

pub fn setX(self: *DOMPoint, v: f64) void {
    self._proto._x = v;
}
pub fn setY(self: *DOMPoint, v: f64) void {
    self._proto._y = v;
}
pub fn setZ(self: *DOMPoint, v: f64) void {
    self._proto._z = v;
}
pub fn setW(self: *DOMPoint, v: f64) void {
    self._proto._w = v;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMPoint);

    pub const Meta = struct {
        pub const name = "DOMPoint";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMPoint.init, .{});
    pub const fromPoint = bridge.function(DOMPoint.fromPoint, .{ .static = true });
    pub const x = bridge.accessor(DOMPoint.getX, DOMPoint.setX, .{});
    pub const y = bridge.accessor(DOMPoint.getY, DOMPoint.setY, .{});
    pub const z = bridge.accessor(DOMPoint.getZ, DOMPoint.setZ, .{});
    pub const w = bridge.accessor(DOMPoint.getW, DOMPoint.setW, .{});
};
