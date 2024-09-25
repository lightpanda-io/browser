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

const parser = @import("netsurf");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const CallbackResult = jsruntime.CallbackResult;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const NodeUnion = @import("node.zig").Union;
const Node = @import("node.zig").Node;

const U32Iterator = @import("../iterator/iterator.zig").U32Iterator;

const log = std.log.scoped(.nodelist);

const DOMException = @import("exceptions.zig").DOMException;

pub const Interfaces = generate.Tuple(.{
    NodeListIterator,
    NodeList,
});

pub const NodeListIterator = struct {
    pub const mem_guarantied = true;

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
    pub const mem_guarantied = true;

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
    pub const mem_guarantied = true;
    pub const Exception = DOMException;

    const NodesArrayList = std.ArrayListUnmanaged(*parser.Node);

    nodes: NodesArrayList,

    pub fn init() NodeList {
        return NodeList{
            .nodes = NodesArrayList{},
        };
    }

    pub fn deinit(self: *NodeList, alloc: std.mem.Allocator) void {
        // TODO unref all nodes
        self.nodes.deinit(alloc);
    }

    pub fn append(self: *NodeList, alloc: std.mem.Allocator, node: *parser.Node) !void {
        try self.nodes.append(alloc, node);
    }

    pub fn get_length(self: *NodeList) u32 {
        return @intCast(self.nodes.items.len);
    }

    pub fn _item(self: *NodeList, index: u32) !?NodeUnion {
        if (index >= self.nodes.items.len) {
            return null;
        }

        const n = self.nodes.items[index];
        return try Node.toInterface(n);
    }

    pub fn _forEach(self: *NodeList, alloc: std.mem.Allocator, cbk: Callback) !void { // TODO handle thisArg
        var res = CallbackResult.init(alloc);
        defer res.deinit();

        for (self.nodes.items, 0..) |n, i| {
            const ii: u32 = @intCast(i);
            cbk.trycall(.{ n, ii, self }, &res) catch |e| {
                log.err("callback error: {s}", .{res.result orelse "unknown"});
                log.debug("{s}", .{res.stack orelse "no stack trace"});

                return e;
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

    pub fn postAttach(self: *NodeList, alloc: std.mem.Allocator, js_obj: jsruntime.JSObject) !void {
        const ln = self.get_length();
        var i: u32 = 0;
        while (i < ln) {
            defer i += 1;
            const k = try std.fmt.allocPrint(alloc, "{d}", .{i});

            const node = try self._item(i) orelse unreachable;
            try js_obj.set(k, node);
        }
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var childnodes = [_]Case{
        .{ .src = "let list = document.getElementById('content').childNodes", .ex = "undefined" },
        .{ .src = "list.length", .ex = "9" },
        .{ .src = "list[0].__proto__.constructor.name", .ex = "Text" },
        .{ .src = 
        \\let i = 0;
        \\list.forEach(function (n, idx) {
        \\  i += idx;
        \\});
        \\i;
        , .ex = "36" },
    };
    try checkCases(js_env, &childnodes);
}
