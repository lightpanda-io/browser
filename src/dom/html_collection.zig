const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const utils = @import("utils.z");
const Element = @import("element.zig").Element;

// WEB IDL https://dom.spec.whatwg.org/#htmlcollection
// HTMLCollection is re implemented in zig here because libdom
// dom_html_collection expects a comparison function callback as arguement.
// But we wanted a dynamically comparison here, according to the match tagname.
pub const HTMLCollection = struct {
    pub const mem_guarantied = true;

    root: *parser.Node,
    // match is used to select node against their name.
    // match comparison is case insensitive.
    match: []const u8,

    // save a state for the collection to improve the _item speed.
    cur_idx: u32 = undefined,
    cur_node: *parser.Node = undefined,

    // next iterates hover the DOM tree to return the next following node or
    // null at the end.
    fn _next(root: *parser.Node, cur: *parser.Node) ?*parser.Node {
        // TODO deinit next
        var next = parser.nodeFirstChild(cur);
        if (next != null) {
            return next;
        }

        // TODO deinit next
        next = parser.nodeNextSibling(cur);
        if (next != null) {
            return next;
        }

        // TODO deinit parent
        var parent = parser.nodeParentNode(cur) orelse unreachable;
        // TODO deinit lastchild
        var lastchild = parser.nodeLastChild(parent);
        var prev = cur;
        while (prev != root and prev == lastchild) {
            prev = parent;
            // TODO deinit parent
            parent = parser.nodeParentNode(cur) orelse unreachable;
            // TODO deinit lastchild
            lastchild = parser.nodeLastChild(parent);
        }

        if (prev == root) {
            return null;
        }

        return parser.nodeNextSibling(prev);
    }

    /// _get_length computes the collection's length dynamically according to
    /// the current root structure.
    // TODO: nodes retrieved must be de-referenced.
    pub fn get_length(self: *HTMLCollection) u32 {
        var len: u32 = 0;
        var node: *parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        // FIXME using a fixed length buffer here avoid the need of an allocator
        // to get an upper case match value. But if the match value (a tag
        // name) is greater than 128 chars, the code will panic.
        // ascii.upperString asserts the buffer size is greater or equals than
        // the given string.
        var buffer: [128]u8 = undefined;
        const imatch = std.ascii.upperString(&buffer, self.match);

        var is_wildcard = std.mem.eql(u8, self.match, "*");

        while (true) {
            ntype = parser.nodeType(node);
            if (ntype == .element) {
                if (is_wildcard or std.mem.eql(u8, imatch, parser.nodeName(node))) {
                    len += 1;
                }
            }

            node = _next(self.root, node) orelse break;
        }

        return len;
    }

    pub fn _item(self: *HTMLCollection, index: u32) ?*parser.Element {
        var i: u32 = 0;
        var node: *parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        var is_wildcard = std.mem.eql(u8, self.match, "*");

        // Use the current state to improve speed if possible.
        if (self.cur_idx != undefined and index >= self.cur_idx) {
            i = self.cur_idx;
            node = self.cur_node;
        }

        // FIXME using a fixed length buffer here avoid the need of an allocator
        // to get an upper case match value. But if the match value (a tag
        // name) is greater than 128 chars, the code will panic.
        // ascii.upperString asserts the buffer size is greater or equals than
        // the given string.
        var buffer: [128]u8 = undefined;
        const imatch = std.ascii.upperString(&buffer, self.match);

        while (true) {
            ntype = parser.nodeType(node);
            if (ntype == .element) {
                if (is_wildcard or std.mem.eql(u8, imatch, parser.nodeName(node))) {
                    // check if we found the searched element.
                    if (i == index) {
                        // save the current state
                        self.cur_node = node;
                        self.cur_idx = i;

                        return @as(*parser.Element, @ptrCast(node));
                    }

                    i += 1;
                }
            }

            node = _next(self.root, node) orelse break;
        }

        return null;
    }

    pub fn _namedItem(self: *HTMLCollection, name: []const u8) ?*parser.Element {
        if (name.len == 0) {
            return null;
        }

        var node: *parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        var is_wildcard = std.mem.eql(u8, self.match, "*");

        // FIXME using a fixed length buffer here avoid the need of an allocator
        // to get an upper case match value. But if the match value (a tag
        // name) is greater than 128 chars, the code will panic.
        // ascii.upperString asserts the buffer size is greater or equals than
        // the given string.
        var buffer: [128]u8 = undefined;
        const imatch = std.ascii.upperString(&buffer, self.match);

        while (true) {
            ntype = parser.nodeType(node);
            if (ntype == .element) {
                if (is_wildcard or std.mem.eql(u8, imatch, parser.nodeName(node))) {
                    const elem = @as(*parser.Element, @ptrCast(node));

                    var attr = parser.elementGetAttribute(elem, "id");
                    // check if the node id corresponds to the name argument.
                    if (attr != null and std.mem.eql(u8, name, attr.?)) {
                        return elem;
                    }

                    attr = parser.elementGetAttribute(elem, "name");
                    // check if the node id corresponds to the name argument.
                    if (attr != null and std.mem.eql(u8, name, attr.?)) {
                        return elem;
                    }
                }
            }

            node = _next(self.root, node) orelse break;
        }

        return null;
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var getElementsByTagName = [_]Case{
        .{ .src = "let getElementsByTagName = document.getElementsByTagName('p')", .ex = "undefined" },
        .{ .src = "getElementsByTagName.length", .ex = "2" },
        .{ .src = "getElementsByTagName.item(0).localName", .ex = "p" },
        .{ .src = "getElementsByTagName.item(1).localName", .ex = "p" },
        .{ .src = "let getElementsByTagNameAll = document.getElementsByTagName('*')", .ex = "undefined" },
        .{ .src = "getElementsByTagNameAll.length", .ex = "8" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(1).localName", .ex = "head" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(2).localName", .ex = "body" },
        .{ .src = "getElementsByTagNameAll.item(3).localName", .ex = "div" },
        .{ .src = "getElementsByTagNameAll.item(7).localName", .ex = "p" },
        .{ .src = "getElementsByTagNameAll.namedItem('para-empty-child').localName", .ex = "span" },
    };
    try checkCases(js_env, &getElementsByTagName);
}
