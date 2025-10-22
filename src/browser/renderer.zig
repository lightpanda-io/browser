// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const parser = @import("netsurf.zig");

const Allocator = std.mem.Allocator;

// provide very poor abstration to the rest of the code. In theory, we can change
// the FlatRenderer to a different implementation, and it'll all just work.
pub const Renderer = FlatRenderer;

// This "renderer" positions elements in a single row in an unspecified order.
// The important thing is that elements have a consistent position/index within
// that row, which can be turned into a rectangle.
const FlatRenderer = struct {
    allocator: Allocator,

    // key is a @ptrFromInt of the element
    // value is the index position
    positions: std.AutoHashMapUnmanaged(u64, u32),

    // given an index, get the element
    elements: std.ArrayListUnmanaged(u64),

    const Element = @import("dom/element.zig").Element;

    // Define the size of each element in the grid.
    const default_w = 5;
    const default_h = 5;

    // we expect allocator to be an arena
    pub fn init(allocator: Allocator) FlatRenderer {
        return .{
            .elements = .{},
            .positions = .{},
            .allocator = allocator,
        };
    }

    // The DOMRect is always relative to the viewport, not the document the element belongs to.
    // Element that are not part of the main document, either detached or in a shadow DOM should not call this function.
    pub fn getRect(self: *FlatRenderer, e: *parser.Element) !Element.DOMRect {
        var elements = &self.elements;
        const gop = try self.positions.getOrPut(self.allocator, @intFromPtr(e));
        var x: u32 = gop.value_ptr.*;
        if (gop.found_existing == false) {
            x = @intCast(elements.items.len);
            try elements.append(self.allocator, @intFromPtr(e));
            gop.value_ptr.* = x;
        }

        const _x: f64 = @floatFromInt(x * default_w);
        const y: f64 = 0.0;
        const w: f64 = default_w;
        const h: f64 = default_h;

        return .{
            .x = _x,
            .y = y,
            .width = w,
            .height = h,
            .left = _x,
            .top = y,
            .right = _x + w,
            .bottom = y + h,
        };
    }

    pub fn boundingRect(self: *const FlatRenderer) Element.DOMRect {
        const x: f64 = 0.0;
        const y: f64 = 0.0;
        const w: f64 = @floatFromInt(self.width());
        const h: f64 = @floatFromInt(self.width());

        return .{
            .x = x,
            .y = y,
            .width = w,
            .height = h,
            .left = x,
            .top = y,
            .right = x + w,
            .bottom = y + h,
        };
    }

    pub fn width(self: *const FlatRenderer) u32 {
        return @max(@as(u32, @intCast(self.elements.items.len * default_w)), default_w); // At least default width pixels even if empty
    }

    pub fn height(_: *const FlatRenderer) u32 {
        return 5;
    }

    pub fn getElementAtPosition(self: *const FlatRenderer, _x: i32, y: i32) ?*parser.Element {
        if (y < 0 or y > default_h or _x < 0) {
            return null;
        }

        const x = @divFloor(_x, default_w);

        const elements = self.elements.items;
        return if (x < elements.len) @ptrFromInt(elements[@intCast(x)]) else null;
    }
};
