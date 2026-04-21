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
const js = @import("../js/js.zig");

const Frame = @import("../Frame.zig");
const Node = @import("Node.zig");
const Element = @import("Element.zig");
const ShadowRoot = @import("ShadowRoot.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");

const DocumentFragment = @This();

_type: Type,
_proto: *Node,

pub const Type = union(enum) {
    generic,
    shadow_root: *ShadowRoot,
};

pub fn is(self: *DocumentFragment, comptime T: type) ?*T {
    switch (self._type) {
        .shadow_root => |shadow_root| {
            if (T == ShadowRoot) {
                return shadow_root;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *DocumentFragment, comptime T: type) *T {
    return self.is(T).?;
}

pub fn init(frame: *Frame) !*DocumentFragment {
    return frame._factory.node(DocumentFragment{
        ._type = .generic,
        ._proto = undefined,
    });
}

pub fn asNode(self: *DocumentFragment) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *DocumentFragment) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getElementById(self: *DocumentFragment, id: []const u8) ?*Element {
    if (id.len == 0) {
        return null;
    }

    var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        if (el.getAttributeSafe(comptime .wrap("id"))) |element_id| {
            if (std.mem.eql(u8, element_id, id)) {
                return el;
            }
        }
    }
    return null;
}

pub fn querySelector(self: *DocumentFragment, selector: []const u8, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), selector, frame);
}

pub fn querySelectorAll(self: *DocumentFragment, input: []const u8, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, frame);
}

pub fn getChildren(self: *DocumentFragment, frame: *Frame) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, frame);
}

pub fn firstElementChild(self: *DocumentFragment) ?*Element {
    var maybe_child = self.asNode().firstChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.nextSibling();
    }
    return null;
}

pub fn lastElementChild(self: *DocumentFragment) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *DocumentFragment) usize {
    var count: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element) != null) {
            count += 1;
        }
    }
    return count;
}

pub fn append(self: *DocumentFragment, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const parent = self.asNode();
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.appendChild(child, frame);
    }
}

pub fn prepend(self: *DocumentFragment, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const parent = self.asNode();
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(frame);
        _ = try parent.insertBefore(child, parent.firstChild(), frame);
    }
}

pub fn replaceChildren(self: *DocumentFragment, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn getInnerHTML(self: *DocumentFragment, writer: *std.Io.Writer, frame: *Frame) !void {
    const dump = @import("../dump.zig");
    return dump.children(self.asNode(), .{ .shadow = .complete }, writer, frame);
}

pub fn setInnerHTML(self: *DocumentFragment, html: []const u8, frame: *Frame) !void {
    const parent = self.asNode();

    frame.domChanged();
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        frame.removeNode(parent, child, .{ .will_be_reconnected = false });
    }

    if (html.len == 0) {
        return;
    }

    try frame.parseHtmlAsChildren(parent, html);
}

pub fn cloneFragment(self: *DocumentFragment, deep: bool, frame: *Frame) !*Node {
    const fragment = try DocumentFragment.init(frame);
    const fragment_node = fragment.asNode();

    if (deep) {
        const node = self.asNode();
        const self_is_connected = node.isConnected();

        var child_it = node.childrenIterator();
        while (child_it.next()) |child| {
            if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                try frame.appendNode(fragment_node, cloned_child, .{ .child_already_connected = self_is_connected });
            }
        }
    }

    return fragment_node;
}

pub fn isEqualNode(self: *DocumentFragment, other: *DocumentFragment) bool {
    var self_iter = self.asNode().childrenIterator();
    var other_iter = other.asNode().childrenIterator();

    while (true) {
        const self_child = self_iter.next();
        const other_child = other_iter.next();

        if ((self_child == null) != (other_child == null)) {
            return false;
        }

        if (self_child == null) {
            // We've reached the end
            return true;
        }

        if (!self_child.?.isEqualNode(other_child.?)) {
            return false;
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DocumentFragment);

    pub const Meta = struct {
        pub const name = "DocumentFragment";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const constructor = bridge.constructor(DocumentFragment.init, .{});

    pub const getElementById = bridge.function(_getElementById, .{});
    fn _getElementById(self: *DocumentFragment, value_: ?js.Value) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) {
            return self.getElementById("null");
        }
        if (value.isUndefined()) {
            return self.getElementById("undefined");
        }
        return self.getElementById(try value.toZig([]const u8));
    }

    pub const querySelector = bridge.function(DocumentFragment.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(DocumentFragment.querySelectorAll, .{ .dom_exception = true });
    pub const children = bridge.accessor(DocumentFragment.getChildren, null, .{});
    pub const childElementCount = bridge.accessor(DocumentFragment.getChildElementCount, null, .{});
    pub const firstElementChild = bridge.accessor(DocumentFragment.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(DocumentFragment.lastElementChild, null, .{});
    pub const append = bridge.function(DocumentFragment.append, .{ .dom_exception = true });
    pub const prepend = bridge.function(DocumentFragment.prepend, .{ .dom_exception = true });
    pub const replaceChildren = bridge.function(DocumentFragment.replaceChildren, .{ .dom_exception = true });
    pub const innerHTML = bridge.accessor(_innerHTML, DocumentFragment.setInnerHTML, .{});

    fn _innerHTML(self: *DocumentFragment, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.call_arena);
        try self.getInnerHTML(&buf.writer, frame);
        return buf.written();
    }
};

const testing = @import("../../testing.zig");
test "WebApi: DocumentFragment" {
    try testing.htmlRunner("document_fragment", .{});
}
