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

const DOMRect = @This();

const std = @import("std");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

_x: f64,
_y: f64,
_width: f64,
_height: f64,

pub fn init(x: f64, y: f64, width: f64, height: f64, page: *Page) !*DOMRect {
    return page._factory.create(DOMRect{
        ._x = x,
        ._y = y,
        ._width = width,
        ._height = height,
    });
}

pub fn getX(self: *const DOMRect) f64 {
    return self._x;
}

pub fn getY(self: *const DOMRect) f64 {
    return self._y;
}

pub fn getWidth(self: *const DOMRect) f64 {
    return self._width;
}

pub fn getHeight(self: *const DOMRect) f64 {
    return self._height;
}

pub fn getTop(self: *const DOMRect) f64 {
    return @min(self._y, self._y + self._height);
}

pub fn getRight(self: *const DOMRect) f64 {
    return @max(self._x, self._x + self._width);
}

pub fn getBottom(self: *const DOMRect) f64 {
    return @max(self._y, self._y + self._height);
}

pub fn getLeft(self: *const DOMRect) f64 {
    return @min(self._x, self._x + self._width);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMRect);

    pub const Meta = struct {
        pub const name = "DOMRect";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMRect.init, .{});
    pub const x = bridge.accessor(DOMRect.getX, null, .{});
    pub const y = bridge.accessor(DOMRect.getY, null, .{});
    pub const width = bridge.accessor(DOMRect.getWidth, null, .{});
    pub const height = bridge.accessor(DOMRect.getHeight, null, .{});
    pub const top = bridge.accessor(DOMRect.getTop, null, .{});
    pub const right = bridge.accessor(DOMRect.getRight, null, .{});
    pub const bottom = bridge.accessor(DOMRect.getBottom, null, .{});
    pub const left = bridge.accessor(DOMRect.getLeft, null, .{});
};
