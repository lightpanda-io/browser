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
const Factory = @import("../Factory.zig");

const DOMRect = @import("DOMRect.zig");

const DOMRectReadOnly = @This();

pub const _prototype_root = true;

_type: Type,

_x: f64,
_y: f64,
_width: f64,
_height: f64,

pub const Type = union(enum) {
    generic,
    mutable: *DOMRect,
};

pub const Data = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
};

pub fn init(x_: ?f64, y_: ?f64, width_: ?f64, height_: ?f64, exec: *const js.Execution) !*DOMRectReadOnly {
    return createBare(.{
        .x = x_ orelse 0,
        .y = y_ orelse 0,
        .width = width_ orelse 0,
        .height = height_ orelse 0,
    }, exec._factory);
}

pub fn createBare(rect: Data, factory: *Factory) !*DOMRectReadOnly {
    return factory.create(DOMRectReadOnly{
        ._type = .generic,
        ._x = rect.x,
        ._y = rect.y,
        ._width = rect.width,
        ._height = rect.height,
    });
}

pub fn fromRect(other_: ?Data, exec: *const js.Execution) !*DOMRectReadOnly {
    return createBare(other_ orelse .{}, exec._factory);
}

pub fn structuredSerialize(self: *const DOMRectReadOnly, writer: *js.StructuredWriter) !void {
    writer.writeUint64(@bitCast(self._x));
    writer.writeUint64(@bitCast(self._y));
    writer.writeUint64(@bitCast(self._width));
    writer.writeUint64(@bitCast(self._height));
}

pub fn readData(reader: *js.StructuredReader) !Data {
    return .{
        .x = @bitCast(try reader.readUint64()),
        .y = @bitCast(try reader.readUint64()),
        .width = @bitCast(try reader.readUint64()),
        .height = @bitCast(try reader.readUint64()),
    };
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*DOMRectReadOnly {
    return createBare(try readData(reader), &page.factory);
}

pub fn getX(self: *const DOMRectReadOnly) f64 {
    return self._x;
}

pub fn getY(self: *const DOMRectReadOnly) f64 {
    return self._y;
}

pub fn getWidth(self: *const DOMRectReadOnly) f64 {
    return self._width;
}

pub fn getHeight(self: *const DOMRectReadOnly) f64 {
    return self._height;
}

pub fn getTop(self: *const DOMRectReadOnly) f64 {
    return @min(self._y, self._y + self._height);
}

pub fn getRight(self: *const DOMRectReadOnly) f64 {
    return @max(self._x, self._x + self._width);
}

pub fn getBottom(self: *const DOMRectReadOnly) f64 {
    return @max(self._y, self._y + self._height);
}

pub fn getLeft(self: *const DOMRectReadOnly) f64 {
    return @min(self._x, self._x + self._width);
}

pub fn toJSON(self: *const DOMRectReadOnly) struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    top: f64,
    right: f64,
    bottom: f64,
    left: f64,
} {
    return .{
        .x = self._x,
        .y = self._y,
        .width = self._width,
        .height = self._height,
        .top = self.getTop(),
        .right = self.getRight(),
        .bottom = self.getBottom(),
        .left = self.getLeft(),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMRectReadOnly);

    pub const Meta = struct {
        pub const name = "DOMRectReadOnly";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMRectReadOnly.init, .{});
    pub const fromRect = bridge.function(DOMRectReadOnly.fromRect, .{ .static = true });

    pub const x = bridge.accessor(DOMRectReadOnly.getX, null, .{});
    pub const y = bridge.accessor(DOMRectReadOnly.getY, null, .{});
    pub const width = bridge.accessor(DOMRectReadOnly.getWidth, null, .{});
    pub const height = bridge.accessor(DOMRectReadOnly.getHeight, null, .{});
    pub const top = bridge.accessor(DOMRectReadOnly.getTop, null, .{});
    pub const right = bridge.accessor(DOMRectReadOnly.getRight, null, .{});
    pub const bottom = bridge.accessor(DOMRectReadOnly.getBottom, null, .{});
    pub const left = bridge.accessor(DOMRectReadOnly.getLeft, null, .{});

    pub const toJSON = bridge.function(DOMRectReadOnly.toJSON, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMRect" {
    try testing.htmlRunner("domrect.html", .{});
}
