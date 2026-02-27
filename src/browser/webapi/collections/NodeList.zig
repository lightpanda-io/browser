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

const log = @import("../../../log.zig");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Node = @import("../Node.zig");

const ChildNodes = @import("ChildNodes.zig");
const RadioNodeList = @import("RadioNodeList.zig");
const SelectorList = @import("../selector/List.zig");
const NodeLive = @import("node_live.zig").NodeLive;

const Mode = enum {
    child_nodes,
    selector_list,
    radio_node_list,
    name,
};

const NodeList = @This();

data: union(Mode) {
    child_nodes: *ChildNodes,
    selector_list: *SelectorList,
    radio_node_list: *RadioNodeList,
    name: NodeLive(.name),
},

pub fn length(self: *NodeList, page: *Page) !u32 {
    return switch (self.data) {
        .child_nodes => |impl| impl.length(page),
        .selector_list => |impl| @intCast(impl.getLength()),
        .radio_node_list => |impl| impl.getLength(),
        .name => |*impl| impl.length(page),
    };
}

pub fn indexedGet(self: *NodeList, index: usize, page: *Page) !*Node {
    return try self.getAtIndex(index, page) orelse return error.NotHandled;
}

pub fn getAtIndex(self: *NodeList, index: usize, page: *Page) !?*Node {
    return switch (self.data) {
        .child_nodes => |impl| impl.getAtIndex(index, page),
        .selector_list => |impl| impl.getAtIndex(index),
        .radio_node_list => |impl| impl.getAtIndex(index, page),
        .name => |*impl| if (impl.getAtIndex(index, page)) |el| el.asNode() else null,
    };
}

pub fn keys(self: *NodeList, page: *Page) !*KeyIterator {
    return .init(.{ .list = self }, page);
}

pub fn values(self: *NodeList, page: *Page) !*ValueIterator {
    return .init(.{ .list = self }, page);
}

pub fn entries(self: *NodeList, page: *Page) !*EntryIterator {
    return .init(.{ .list = self }, page);
}

pub fn forEach(self: *NodeList, cb: js.Function, page: *Page) !void {
    var i: i32 = 0;
    var it = try self.values(page);
    while (true) : (i += 1) {
        const next = try it.next(page);
        if (next.done) {
            return;
        }

        var caught: js.TryCatch.Caught = undefined;
        cb.tryCall(void, .{ next.value, i, self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "nodelist" });
            return;
        };
    }
}

const GenericIterator = @import("iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

const Iterator = struct {
    index: u32 = 0,
    list: *NodeList,

    const Entry = struct { u32, *Node };

    pub fn next(self: *Iterator, page: *Page) !?Entry {
        const index = self.index;
        const node = try self.list.getAtIndex(index, page) orelse return null;
        self.index = index + 1;
        return .{ index, node };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(NodeList);

    pub const Meta = struct {
        pub const name = "NodeList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const length = bridge.accessor(NodeList.length, null, .{});
    pub const @"[]" = bridge.indexed(NodeList.indexedGet, getIndexes, .{ .null_as_undefined = true });
    pub const item = bridge.function(NodeList.getAtIndex, .{});
    pub const keys = bridge.function(NodeList.keys, .{});
    pub const values = bridge.function(NodeList.values, .{});
    pub const entries = bridge.function(NodeList.entries, .{});
    pub const forEach = bridge.function(NodeList.forEach, .{});
    pub const symbol_iterator = bridge.iterator(NodeList.values, .{});

    fn getIndexes(self: *NodeList, page: *Page) !js.Array {
        const len = try self.length(page);
        var arr = page.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};
