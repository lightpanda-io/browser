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
const Element = @import("../Element.zig");

const NodeList = @import("NodeList.zig");
const RadioNodeList = @import("RadioNodeList.zig");
const HTMLCollection = @import("HTMLCollection.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

const HTMLFormControlsCollection = @This();

_proto: *HTMLCollection,

pub const NamedItemResult = union(enum) {
    element: *Element,
    radio_node_list: *RadioNodeList,
};

pub fn length(self: *HTMLFormControlsCollection, page: *Page) u32 {
    return self._proto.length(page);
}

pub fn getAtIndex(self: *HTMLFormControlsCollection, index: usize, page: *Page) ?*Element {
    return self._proto.getAtIndex(index, page);
}

pub fn namedItem(self: *HTMLFormControlsCollection, name: []const u8, page: *Page) !?NamedItemResult {
    if (name.len == 0) {
        return null;
    }

    // We need special handling for radio, where multiple inputs can have the
    // same name, but we also need to handle the [incorrect] case where non-
    // radios share names.

    var count: u32 = 0;
    var first_element: ?*Element = null;

    var it = try self.iterator();
    while (it.next()) |element| {
        const is_match = blk: {
            if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
                if (std.mem.eql(u8, id, name)) {
                    break :blk true;
                }
            }
            if (element.getAttributeSafe(comptime .wrap("name"))) |elem_name| {
                if (std.mem.eql(u8, elem_name, name)) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (is_match) {
            if (first_element == null) {
                first_element = element;
            }
            count += 1;

            if (count == 2) {
                const radio_node_list = try page._factory.create(RadioNodeList{
                    ._proto = undefined,
                    ._form_collection = self,
                    ._name = try page.dupeString(name),
                });

                radio_node_list._proto = try page._factory.create(NodeList{ ._data = .{ .radio_node_list = radio_node_list } });

                return .{ .radio_node_list = radio_node_list };
            }
        }
    }

    if (count == 0) {
        return null;
    }

    // case == 2 was handled inside the loop
    if (comptime IS_DEBUG) {
        std.debug.assert(count == 1);
    }

    return .{ .element = first_element.? };
}

// used internally, by HTMLFormControlsCollection and RadioNodeList
pub fn iterator(self: *HTMLFormControlsCollection) !Iterator {
    const form_collection = self._proto._data.form;
    return .{
        .tw = form_collection._tw.clone(),
        .nodes = form_collection,
    };
}

// Used internally. Presents a nicer (more zig-like) iterator and strips away
// some of the abstraction.
pub const Iterator = struct {
    tw: TreeWalker,
    nodes: NodeLive,

    const NodeLive = @import("node_live.zig").NodeLive(.form);
    const TreeWalker = @import("../TreeWalker.zig").FullExcludeSelf;

    pub fn next(self: *Iterator) ?*Element {
        return self.nodes.nextTw(&self.tw);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLFormControlsCollection);

    pub const Meta = struct {
        pub const name = "HTMLFormControlsCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const manage = false;
    };

    pub const length = bridge.accessor(HTMLFormControlsCollection.length, null, .{});
    pub const @"[int]" = bridge.indexed(HTMLFormControlsCollection.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(HTMLFormControlsCollection.namedItem, null, null, .{ .null_as_undefined = true });
    pub const namedItem = bridge.function(HTMLFormControlsCollection.namedItem, .{});
};
