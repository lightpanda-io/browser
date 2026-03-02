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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const HTMLCollection = @import("HTMLCollection.zig");

const HTMLOptionsCollection = @This();

_proto: *HTMLCollection,
_select: *@import("../element/html/Select.zig"),

// Forward length to HTMLCollection
pub fn length(self: *HTMLOptionsCollection, page: *Page) u32 {
    return self._proto.length(page);
}

// Forward indexed access to HTMLCollection
pub fn getAtIndex(self: *HTMLOptionsCollection, index: usize, page: *Page) ?*Element {
    return self._proto.getAtIndex(index, page);
}

pub fn getByName(self: *HTMLOptionsCollection, name: []const u8, page: *Page) ?*Element {
    return self._proto.getByName(name, page);
}

// Forward selectedIndex to the owning select element
pub fn getSelectedIndex(self: *const HTMLOptionsCollection) i32 {
    return self._select.getSelectedIndex();
}

pub fn setSelectedIndex(self: *HTMLOptionsCollection, index: i32) !void {
    return self._select.setSelectedIndex(index);
}

const Option = @import("../element/html/Option.zig");

const AddBeforeOption = union(enum) {
    option: *Option,
    index: u32,
};

// Add a new option element
pub fn add(self: *HTMLOptionsCollection, element: *Option, before_: ?AddBeforeOption, page: *Page) !void {
    const select_node = self._select.asNode();
    const element_node = element.asElement().asNode();

    var before_node: ?*Node = null;
    if (before_) |before| {
        switch (before) {
            .index => |idx| {
                if (self.getAtIndex(idx, page)) |el| {
                    before_node = el.asNode();
                }
            },
            .option => |before_option| before_node = before_option.asNode(),
        }
    }
    _ = try select_node.insertBefore(element_node, before_node, page);
}

// Remove an option element by index
pub fn remove(self: *HTMLOptionsCollection, index: i32, page: *Page) void {
    if (index < 0) {
        return;
    }

    if (self._proto.getAtIndex(@intCast(index), page)) |element| {
        element.remove(page);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLOptionsCollection);

    pub const Meta = struct {
        pub const name = "HTMLOptionsCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const manage = false;
    };

    pub const length = bridge.accessor(HTMLOptionsCollection.length, null, .{});

    // Indexed access
    pub const @"[int]" = bridge.indexed(HTMLOptionsCollection.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(HTMLOptionsCollection.getByName, null, null, .{ .null_as_undefined = true });

    pub const selectedIndex = bridge.accessor(HTMLOptionsCollection.getSelectedIndex, HTMLOptionsCollection.setSelectedIndex, .{});
    pub const add = bridge.function(HTMLOptionsCollection.add, .{});
    pub const remove = bridge.function(HTMLOptionsCollection.remove, .{});
};
