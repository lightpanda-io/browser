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

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");

const JsThis = @import("../env.zig").JsThis;
const Function = @import("../env.zig").Function;

const NodeUnion = @import("node.zig").Union;
const Node = @import("node.zig").Node;

const U32Iterator = @import("../iterator/iterator.zig").U32Iterator;

const DOMException = @import("exceptions.zig").DOMException;

pub const Interfaces = .{
    NodeListIterator,
    NodeList,
};

pub const NodeListIterator = struct {
    coll: *NodeList,
    index: u32 = 0,

    pub const Return = struct {
        value: ?NodeUnion,
        done: bool,
    };

    pub fn _next(self: *NodeListIterator) !Return {
        const e = try self.coll._item(self.index);
        if (e == null) {
            return Return{
                .value = null,
                .done = true,
            };
        }

        self.index += 1;
        return Return{
            .value = e,
            .done = false,
        };
    }
};

pub const NodeListEntriesIterator = struct {
    coll: *NodeList,
    index: u32 = 0,

    pub const Return = struct {
        value: ?NodeUnion,
        done: bool,
    };

    pub fn _next(self: *NodeListEntriesIterator) !Return {
        const e = try self.coll._item(self.index);
        if (e == null) {
            return Return{
                .value = null,
                .done = true,
            };
        }

        self.index += 1;
        return Return{
            .value = e,
            .done = false,
        };
    }
};

// Nodelist is implemented in pure Zig b/c libdom's NodeList doesn't allow to
// append nodes.
// WEB IDL https://dom.spec.whatwg.org/#nodelist
//
// TODO: a Nodelist can be either static or live. But the current
// implementation allows only static nodelist.
// see https://dom.spec.whatwg.org/#old-style-collections
pub const NodeList = struct {
    pub const Exception = DOMException;
    const NodesArrayList = std.ArrayListUnmanaged(*parser.Node);

    nodes: NodesArrayList = .{},

    pub fn deinit(self: *NodeList, alloc: std.mem.Allocator) void {
        // TODO unref all nodes
        self.nodes.deinit(alloc);
    }

    pub fn append(self: *NodeList, alloc: std.mem.Allocator, node: *parser.Node) !void {
        try self.nodes.append(alloc, node);
    }

    pub fn get_length(self: *const NodeList) u32 {
        return @intCast(self.nodes.items.len);
    }

    pub fn _item(self: *const NodeList, index: u32) !?NodeUnion {
        if (index >= self.nodes.items.len) {
            return null;
        }

        const n = self.nodes.items[index];
        return try Node.toInterface(n);
    }

    // This code works, but it's _MUCH_ slower than using postAttach. The benefit
    // of this version, is that it's "live"..but we're talking many orders of
    // magnitude slower.
    //
    // You can test it by commenting out `postAttach`, uncommenting this and
    // running:
    //    zig build wpt --  tests/wpt/dom/nodes/NodeList-static-length-getter-tampered-indexOf-1.html
    //
    // I think this _is_ the right way to do it, but I must be doing something
    // wrong to make it so slow.
    // pub fn indexed_get(self: *const NodeList, index: u32, has_value: *bool) !?NodeUnion {
    //     return (try self._item(index)) orelse {
    //         has_value.* = false;
    //         return null;
    //     };
    // }

    pub fn _forEach(self: *NodeList, cbk: Function) !void { // TODO handle thisArg
        for (self.nodes.items, 0..) |n, i| {
            const ii: u32 = @intCast(i);
            var result: Function.Result = undefined;
            cbk.tryCall(void, .{ n, ii, self }, &result) catch {
                log.debug(.user_script, "forEach callback", .{ .err = result.exception, .stack = result.stack });
            };
        }
    }

    pub fn _keys(self: *NodeList) U32Iterator {
        return .{
            .length = self.get_length(),
        };
    }

    pub fn _values(self: *NodeList) NodeListIterator {
        return .{
            .coll = self,
        };
    }

    pub fn _symbol_iterator(self: *NodeList) NodeListIterator {
        return self._values();
    }

    // TODO entries() https://developer.mozilla.org/en-US/docs/Web/API/NodeList/entries
    pub fn postAttach(self: *NodeList, js_this: JsThis) !void {
        const len = self.get_length();
        for (0..len) |i| {
            const node = try self._item(@intCast(i)) orelse unreachable;
            try js_this.setIndex(@intCast(i), node, .{});
        }
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.NodeList" {
    try testing.htmlRunner("dom/node_list.html");
}
