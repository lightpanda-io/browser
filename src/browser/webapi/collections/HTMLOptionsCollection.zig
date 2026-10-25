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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const Select = @import("../element/html/Select.zig");

const HTMLCollection = @import("HTMLCollection.zig");

const HTMLOptionsCollection = @This();

pub const Proto = HTMLCollection;

_proto: *HTMLCollection,
_select: *Select,

// The refcount lives on the proto, but the finalizer anchors here so deinit
// destroys the whole {HTMLCollection, self} chain from its leaf.
pub fn deinit(self: *HTMLOptionsCollection, page: *Page) void {
    page.factory.destroy(self);
}

pub fn acquireRef(self: *HTMLOptionsCollection) void {
    self._proto.acquireRef();
}

pub fn releaseRef(self: *HTMLOptionsCollection, page: *Page) void {
    self._proto._rc.release(self, page);
}

// Forward length to HTMLCollection
pub fn length(self: *HTMLOptionsCollection, frame: *Frame) u32 {
    return self._proto.length(frame);
}

fn setLength(self: *HTMLOptionsCollection, value: u32, frame: *Frame) !void {
    return self._select.setLength(value, frame);
}

// Forward indexed access to HTMLCollection
pub fn getAtIndex(self: *HTMLOptionsCollection, index: usize, frame: *Frame) ?*Element {
    return self._proto.getAtIndex(index, frame);
}

pub fn getByName(self: *HTMLOptionsCollection, name: []const u8) ?*Element {
    return self._proto.getByName(name);
}

// Forward selectedIndex to the owning select element
pub fn getSelectedIndex(self: *const HTMLOptionsCollection) i32 {
    return self._select.getSelectedIndex();
}

fn setSelectedIndex(self: *HTMLOptionsCollection, index: i32, frame: *Frame) !void {
    return self._select.setSelectedIndex(index, frame);
}

const Option = @import("../element/html/Option.zig");

const AddBeforeOption = union(enum) {
    option: *Option,
    index: u32,
};

// Add a new option element
pub fn add(self: *HTMLOptionsCollection, element: *Option, before_: ?AddBeforeOption, frame: *Frame) !void {
    const select_node = self._select.asNode();
    const element_node = element.asElement().asNode();

    var before_node: ?*Node = null;
    if (before_) |before| {
        switch (before) {
            .index => |idx| {
                if (self.getAtIndex(idx, frame)) |el| {
                    before_node = el.asNode();
                }
            },
            .option => |before_option| before_node = before_option.asNode(),
        }
    }
    _ = try select_node.insertBefore(element_node, before_node, frame);
}

// Remove an option element by index
pub fn remove(self: *HTMLOptionsCollection, index: i32, frame: *Frame) void {
    if (index < 0) {
        return;
    }

    if (self._proto.getAtIndex(@intCast(index), frame)) |element| {
        element.remove(frame);
    }
}

// The indexed setter: null removes the option at index; an index past the
// end pads with blank options and then appends; otherwise the option at
// index is replaced.
fn setAtIndex(self: *HTMLOptionsCollection, index: u32, option_: ?*Option, frame: *Frame) !void {
    const existing = self.getAtIndex(index, frame);
    const option = (option_ orelse {
        if (existing) |element| {
            element.remove(frame);
        }
        return;
    }).asElement().asNode();

    if (existing) |element| {
        const old = element.asNode();
        _ = try old.parentNode().?.replaceChild(option, old, frame);
        return;
    }

    if (index >= Select.max_list_items) {
        lp.log.debug(.js, "select overflow", .{ .max_list_items = Select.max_list_items, .request = index });
        return;
    }

    const select_node = self._select.asNode();
    const len = self.length(frame);
    if (index > len) {
        // Per spec, the padding goes in as one DocumentFragment, so observers
        // get one record rather than one per blank option.
        const doc = select_node.ownerDocument(frame).?;
        const fragment = (try Node.DocumentFragment.init(doc, frame)).asNode();
        for (len..index) |_| {
            const blank = try Frame.node_factory.createElementNS(doc, .html, "option", null);
            _ = try fragment.appendChild(blank, frame);
        }
        _ = try select_node.appendChild(fragment, frame);
    }
    _ = try select_node.appendChild(option, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLOptionsCollection);

    pub const Meta = struct {
        pub const name = "HTMLOptionsCollection";
        pub var class_id: bridge.ClassId = undefined;
        pub const manage = false;
    };

    pub const length = bridge.accessor(HTMLOptionsCollection.length, setLength, .{ .ce_reactions = true });

    // Indexed access
    pub const @"[int]" = bridge.indexedReadWrite(HTMLOptionsCollection.getAtIndex, setAtIndex, null, null, null, .{ .null_as_undefined = true, .ce_reactions = true });
    pub const @"[str]" = bridge.namedIndexed(HTMLOptionsCollection.getByName, null, null, null, struct {
        fn wrap(self: *HTMLOptionsCollection, name: []const u8) !u32 {
            if (self.getByName(name) != null) {
                // Named properties are [LegacyUnenumerableNamedProperties]: the query
                return js.v8.DontEnum;
            }
            return error.NotHandled;
        }
    }.wrap, .{ .null_as_undefined = true });

    pub const selectedIndex = bridge.accessor(HTMLOptionsCollection.getSelectedIndex, HTMLOptionsCollection.setSelectedIndex, .{});
    pub const add = bridge.function(HTMLOptionsCollection.add, .{ .ce_reactions = true });
    pub const remove = bridge.function(HTMLOptionsCollection.remove, .{ .ce_reactions = true });
};
