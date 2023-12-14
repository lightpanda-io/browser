const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const NodeUnion = @import("node.zig").Union;
const Node = @import("node.zig").Node;

const DOMException = @import("exceptions.zig").DOMException;

// Nodelist is implemented in pure Zig b/c libdom's NodeList doesn't allow to
// append nodes.
// WEB IDL https://dom.spec.whatwg.org/#nodelist
pub const NodeList = struct {
    pub const mem_guarantied = true;
    pub const Exception = DOMException;

    const NodesArrayList = std.ArrayList(*parser.Node);

    nodes: NodesArrayList,

    pub fn init(alloc: std.mem.Allocator) !*NodeList {
        const list = try alloc.create(NodeList);
        list.* = NodeList{
            .nodes = NodesArrayList.init(alloc),
        };

        return list;
    }

    pub fn deinit(self: *NodeList, alloc: std.mem.Allocator) void {
        // TODO unref all nodes
        self.nodes.deinit();
        alloc.destroy(self);
    }

    pub fn append(self: *NodeList, node: *parser.Node) !void {
        try self.nodes.append(node);
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

    // TODO _symbol_iterator

    // TODO implement postAttach
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var childnodes = [_]Case{
        .{ .src = "let list = document.getElementById('content').childNodes", .ex = "undefined" },
        .{ .src = "list.length", .ex = "9" },
    };
    try checkCases(js_env, &childnodes);
}
