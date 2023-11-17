const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const utils = @import("utils.z");
const Element = @import("element.zig").Element;
const Union = @import("element.zig").Union;

const Match = union(enum) {
    matchByTagName: MatchByTagName,
    matchByClassName: MatchByClassName,

    pub fn match(self: Match, node: *parser.Node) bool {
        switch (self) {
            inline else => |case| return case.match(node),
        }
    }

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self) {
            inline else => return,
        }
    }
};

pub const MatchByTagName = struct {
    // tag is used to select node against their name.
    // tag comparison is case insensitive.
    tag: []const u8,
    is_wildcard: bool,

    fn init(tag_name: []const u8) !MatchByTagName {
        return MatchByTagName{
            .tag = tag_name,
            .is_wildcard = std.mem.eql(u8, tag_name, "*"),
        };
    }

    pub fn match(self: MatchByTagName, node: *parser.Node) bool {
        return self.is_wildcard or std.ascii.eqlIgnoreCase(self.tag, parser.nodeName(node));
    }
};

pub fn HTMLCollectionByTagName(root: *parser.Node, tag_name: []const u8) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .match = Match{
            .matchByTagName = try MatchByTagName.init(tag_name),
        },
    };
}

pub const MatchByClassName = struct {
    classNames: []const u8,

    fn init(classNames: []const u8) !MatchByClassName {
        return MatchByClassName{
            .classNames = classNames,
        };
    }

    pub fn match(self: MatchByClassName, node: *parser.Node) bool {
        var it = std.mem.splitAny(u8, self.classNames, " ");
        const e = parser.nodeToElement(node);
        while (it.next()) |c| {
            if (!parser.elementHasClass(e, c)) {
                return false;
            }
        }

        return true;
    }
};

pub fn HTMLCollectionByClassName(root: *parser.Node, classNames: []const u8) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .match = Match{
            .matchByClassName = try MatchByClassName.init(classNames),
        },
    };
}

// WEB IDL https://dom.spec.whatwg.org/#htmlcollection
// HTMLCollection is re implemented in zig here because libdom
// dom_html_collection expects a comparison function callback as arguement.
// But we wanted a dynamically comparison here, according to the match tagname.
pub const HTMLCollection = struct {
    pub const mem_guarantied = true;

    match: Match,

    root: *parser.Node,

    // save a state for the collection to improve the _item speed.
    cur_idx: ?u32 = undefined,
    cur_node: ?*parser.Node = undefined,

    pub fn deinit(self: *HTMLCollection, allocator: std.mem.Allocator) void {
        self.match.deinit(allocator);
    }

    // get_next iterates over the DOM tree to return the next following node or
    // null at the end.
    //
    // This implementation is a zig version of Netsurf code.
    // http://source.netsurf-browser.org/libdom.git/tree/src/html/html_collection.c#n177
    //
    // The iteration is a depth first as required by the specification.
    // https://dom.spec.whatwg.org/#htmlcollection
    // https://dom.spec.whatwg.org/#concept-tree-order
    fn get_next(root: *parser.Node, cur: *parser.Node) ?*parser.Node {
        // TODO deinit next
        if (parser.nodeFirstChild(cur)) |next| {
            return next;
        }

        // TODO deinit next
        if (parser.nodeNextSibling(cur)) |next| {
            return next;
        }

        // TODO deinit parent
        // Back to the parent of cur.
        // If cur has no parent, then the iteration is over.
        var parent = parser.nodeParentNode(cur) orelse return null;

        // TODO deinit lastchild
        var lastchild = parser.nodeLastChild(parent);
        var prev = cur;
        while (prev != root and prev == lastchild) {
            prev = parent;

            // TODO deinit parent
            // Back to the prev's parent.
            // If prev has no parent, then the loop must stop.
            parent = parser.nodeParentNode(prev) orelse break;

            // TODO deinit lastchild
            lastchild = parser.nodeLastChild(parent);
        }

        if (prev == root) {
            return null;
        }

        return parser.nodeNextSibling(prev);
    }

    /// get_length computes the collection's length dynamically according to
    /// the current root structure.
    // TODO: nodes retrieved must be de-referenced.
    pub fn get_length(self: *HTMLCollection) u32 {
        var len: u32 = 0;
        var node: *parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        while (true) {
            ntype = parser.nodeType(node);
            if (ntype == .element) {
                if (self.match.match(node)) {
                    len += 1;
                }
            }

            node = get_next(self.root, node) orelse break;
        }

        return len;
    }

    pub fn _item(self: *HTMLCollection, index: u32) ?Union {
        var i: u32 = 0;
        var node: *parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        // Use the current state to improve speed if possible.
        if (self.cur_idx != null and index >= self.cur_idx.?) {
            i = self.cur_idx.?;
            node = self.cur_node.?;
        }

        while (true) {
            ntype = parser.nodeType(node);
            if (ntype == .element) {
                if (self.match.match(node)) {
                    // check if we found the searched element.
                    if (i == index) {
                        // save the current state
                        self.cur_node = node;
                        self.cur_idx = i;

                        const e = @as(*parser.Element, @ptrCast(node));
                        return Element.toInterface(e);
                    }

                    i += 1;
                }
            }

            node = get_next(self.root, node) orelse break;
        }

        return null;
    }

    pub fn _namedItem(self: *HTMLCollection, name: []const u8) ?Union {
        if (name.len == 0) {
            return null;
        }

        var node: *parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        while (true) {
            ntype = parser.nodeType(node);
            if (ntype == .element) {
                if (self.match.match(node)) {
                    const elem = @as(*parser.Element, @ptrCast(node));

                    var attr = parser.elementGetAttribute(elem, "id");
                    // check if the node id corresponds to the name argument.
                    if (attr != null and std.mem.eql(u8, name, attr.?)) {
                        return Element.toInterface(elem);
                    }

                    attr = parser.elementGetAttribute(elem, "name");
                    // check if the node id corresponds to the name argument.
                    if (attr != null and std.mem.eql(u8, name, attr.?)) {
                        return Element.toInterface(elem);
                    }
                }
            }

            node = get_next(self.root, node) orelse break;
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
        .{ .src = "let getElementsByTagNameCI = document.getElementsByTagName('P')", .ex = "undefined" },
        .{ .src = "getElementsByTagNameCI.length", .ex = "2" },
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
