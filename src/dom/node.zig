const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const EventTarget = @import("event_target.zig").EventTarget;
const CData = @import("character_data.zig");
const HTMLDocument = @import("../html/document.zig").HTMLDocument;
const HTMLElem = @import("../html/elements.zig");

pub const Node = struct {
    pub const Self = parser.Node;
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;

    pub fn toInterface(node: *parser.Node) Union {
        return switch (parser.nodeType(node)) {
            .element => HTMLElem.toInterface(Union, @as(*parser.Element, @ptrCast(node))),
            .comment => .{ .Comment = @as(*parser.Comment, @ptrCast(node)) },
            .text => .{ .Text = @as(*parser.Text, @ptrCast(node)) },
            .document => .{ .HTMLDocument = @as(*parser.DocumentHTML, @ptrCast(node)) },
            else => @panic("node type not handled"), // TODO
        };
    }

    // JS funcs
    // --------

    // Read-only attributes

    pub fn get_firstChild(self: *parser.Node) ?Union {
        const res = parser.nodeFirstChild(self);
        if (res == null) {
            return null;
        }
        return Node.toInterface(res.?);
    }

    pub fn get_lastChild(self: *parser.Node) ?Union {
        const res = parser.nodeLastChild(self);
        if (res == null) {
            return null;
        }
        return Node.toInterface(res.?);
    }

    pub fn get_nextSibling(self: *parser.Node) ?Union {
        const res = parser.nodeNextSibling(self);
        if (res == null) {
            return null;
        }
        return Node.toInterface(res.?);
    }

    pub fn get_previousSibling(self: *parser.Node) ?Union {
        const res = parser.nodePreviousSibling(self);
        if (res == null) {
            return null;
        }
        return Node.toInterface(res.?);
    }

    pub fn get_parentNode(self: *parser.Node) ?Union {
        const res = parser.nodeParentNode(self);
        if (res == null) {
            return null;
        }
        return Node.toInterface(res.?);
    }

    pub fn get_parentElement(self: *parser.Node) ?HTMLElem.Union {
        const res = parser.nodeParentElement(self);
        if (res == null) {
            return null;
        }
        return HTMLElem.toInterface(HTMLElem.Union, @as(*parser.Element, @ptrCast(res.?)));
    }

    pub fn get_nodeName(self: *parser.Node) []const u8 {
        return parser.nodeName(self);
    }

    pub fn get_nodeType(self: *parser.Node) u8 {
        return @intFromEnum(parser.nodeType(self));
    }

    pub fn get_ownerDocument(self: *parser.Node) ?*parser.DocumentHTML {
        const res = parser.nodeOwnerDocument(self);
        if (res == null) {
            return null;
        }
        return @as(*parser.DocumentHTML, @ptrCast(res.?));
    }

    pub fn get_isConnected(self: *parser.Node) bool {
        // TODO: handle Shadow DOM
        if (parser.nodeType(self) == .document) {
            return true;
        }
        return Node.get_parentNode(self) != null;
    }

    // Read/Write attributes

    pub fn get_nodeValue(self: *parser.Node) ?[]const u8 {
        return parser.nodeValue(self);
    }

    pub fn set_nodeValue(self: *parser.Node, data: []u8) void {
        parser.nodeSetValue(self, data);
    }

    pub fn get_textContent(self: *parser.Node) ?[]const u8 {
        return parser.nodeTextContent(self);
    }

    pub fn set_textContent(self: *parser.Node, data: []u8) void {
        return parser.nodeSetTextContent(self, data);
    }

    // Methods

    pub fn _appendChild(self: *parser.Node, child: *parser.Node) Union {
        // TODO: DocumentFragment special case
        const res = parser.nodeAppendChild(self, child);
        return Node.toInterface(res);
    }

    pub fn _cloneNode(self: *parser.Node, deep: ?bool) Union {
        const is_deep = if (deep) |deep_set| deep_set else false;
        const clone = parser.nodeCloneNode(self, is_deep);
        return Node.toInterface(clone);
    }

    pub fn _compareDocumentPosition(self: *parser.Node, other: *parser.Node) void {
        _ = other;
        _ = self;
        @panic("Not implemented node.compareDocumentPosition()");
    }

    pub fn _contains(self: *parser.Node, other: *parser.Node) bool {
        return parser.nodeContains(self, other);
    }

    pub fn _getRootNode(self: *parser.Node) void {
        _ = self;
        @panic("Not implemented node.getRootNode()");
    }

    pub fn _hasChildNodes(self: *parser.Node) bool {
        return parser.nodeHasChildNodes(self);
    }

    pub fn _insertBefore(self: *parser.Node, new_node: *parser.Node, ref_node: *parser.Node) *parser.Node {
        return parser.nodeInsertBefore(self, new_node, ref_node);
    }
};

pub const Types = generate.Tuple(.{
    CData.Types,
    HTMLElem.Types,
    HTMLDocument,
});
const Generated = generate.Union.compile(Types);
pub const Union = Generated._union;
pub const Tags = Generated._enum;

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var first_child = [_]Case{
        // for next test cases
        .{ .src = "let content = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "let link = document.getElementById('link')", .ex = "undefined" },

        .{ .src = "let first_child = document.body.firstChild", .ex = "undefined" },
        .{ .src = "first_child.localName", .ex = "div" },
        .{ .src = "first_child.__proto__.constructor.name", .ex = "HTMLDivElement" },
        .{ .src = "document.getElementById('para-empty').firstChild.firstChild", .ex = "null" },
    };
    try checkCases(js_env, &first_child);

    var last_child = [_]Case{
        .{ .src = "let last_child = content.lastChild", .ex = "undefined" },
        .{ .src = "last_child.__proto__.constructor.name", .ex = "Comment" },
    };
    try checkCases(js_env, &last_child);

    var next_sibling = [_]Case{
        .{ .src = "let next_sibling = link.nextSibling", .ex = "undefined" },
        .{ .src = "next_sibling.localName", .ex = "p" },
        .{ .src = "next_sibling.__proto__.constructor.name", .ex = "HTMLParagraphElement" },
        .{ .src = "content.nextSibling", .ex = "null" },
    };
    try checkCases(js_env, &next_sibling);

    var prev_sibling = [_]Case{
        .{ .src = "let prev_sibling = document.getElementById('para-empty').previousSibling", .ex = "undefined" },
        .{ .src = "prev_sibling.localName", .ex = "a" },
        .{ .src = "prev_sibling.__proto__.constructor.name", .ex = "HTMLAnchorElement" },
        .{ .src = "content.previousSibling", .ex = "null" },
    };
    try checkCases(js_env, &prev_sibling);

    var parent = [_]Case{
        .{ .src = "let parent = document.getElementById('para').parentElement", .ex = "undefined" },
        .{ .src = "parent.localName", .ex = "div" },
        .{ .src = "parent.__proto__.constructor.name", .ex = "HTMLDivElement" },
        .{ .src = "let h = content.parentElement.parentElement", .ex = "undefined" },
        .{ .src = "h.parentElement", .ex = "null" },
        .{ .src = "h.parentNode.__proto__.constructor.name", .ex = "HTMLDocument" },
    };
    try checkCases(js_env, &parent);

    var node_name = [_]Case{
        .{ .src = "content.firstChild.nodeName === 'A'", .ex = "true" },
        .{ .src = "link.firstChild.nodeName === '#text'", .ex = "true" },
        .{ .src = "content.lastChild.nodeName === '#comment'", .ex = "true" },
        .{ .src = "document.nodeName === '#document'", .ex = "true" },
    };
    try checkCases(js_env, &node_name);

    var node_type = [_]Case{
        .{ .src = "content.firstChild.nodeType === 1", .ex = "true" },
        .{ .src = "link.firstChild.nodeType === 3", .ex = "true" },
        .{ .src = "content.lastChild.nodeType === 8", .ex = "true" },
        .{ .src = "document.nodeType === 9", .ex = "true" },
    };
    try checkCases(js_env, &node_type);

    var owner = [_]Case{
        .{ .src = "let owner = content.ownerDocument", .ex = "undefined" },
        .{ .src = "owner.__proto__.constructor.name", .ex = "HTMLDocument" },
        .{ .src = "document.ownerDocument", .ex = "null" },
        .{ .src = "let owner2 = document.createElement('div').ownerDocument", .ex = "undefined" },
        .{ .src = "owner2.__proto__.constructor.name", .ex = "HTMLDocument" },
    };
    try checkCases(js_env, &owner);

    var connected = [_]Case{
        .{ .src = "content.isConnected", .ex = "true" },
        .{ .src = "document.isConnected", .ex = "true" },
        .{ .src = "document.createElement('div').isConnected", .ex = "false" },
    };
    try checkCases(js_env, &connected);

    var node_value = [_]Case{
        .{ .src = "content.lastChild.nodeValue === 'comment'", .ex = "true" },
        .{ .src = "link.nodeValue === null", .ex = "true" },
        .{ .src = "let text = link.firstChild", .ex = "undefined" },
        .{ .src = "text.nodeValue === 'OK'", .ex = "true" },
        .{ .src = "text.nodeValue = 'OK modified'", .ex = "OK modified" },
        .{ .src = "text.nodeValue === 'OK modified'", .ex = "true" },
        .{ .src = "link.nodeValue = 'nothing'", .ex = "nothing" },
    };
    try checkCases(js_env, &node_value);

    var node_text_content = [_]Case{
        .{ .src = "text.textContent === 'OK modified'", .ex = "true" },
        .{ .src = "content.textContent === 'OK modified And'", .ex = "true" },
        .{ .src = "text.textContent = 'OK'", .ex = "OK" },
        .{ .src = "text.textContent", .ex = "OK" },
        .{ .src = "document.getElementById('para-empty').textContent", .ex = "" },
        .{ .src = "document.getElementById('para-empty').textContent = 'OK'", .ex = "OK" },
        .{ .src = "document.getElementById('para-empty').firstChild.nodeName === '#text'", .ex = "true" },
    };
    try checkCases(js_env, &node_text_content);

    var node_append_child = [_]Case{
        .{ .src = "let append = document.createElement('h1')", .ex = "undefined" },
        .{ .src = "content.appendChild(append).toString()", .ex = "[object HTMLHeadingElement]" },
        .{ .src = "content.lastChild.__proto__.constructor.name", .ex = "HTMLHeadingElement" },
        .{ .src = "content.appendChild(link).toString()", .ex = "[object HTMLAnchorElement]" },
    };
    try checkCases(js_env, &node_append_child);

    var node_clone = [_]Case{
        .{ .src = "let clone = link.cloneNode()", .ex = "undefined" },
        .{ .src = "clone.toString()", .ex = "[object HTMLAnchorElement]" },
        .{ .src = "clone.parentNode === null", .ex = "true" },
        .{ .src = "clone.firstChild === null", .ex = "true" },
        .{ .src = "let clone_deep = link.cloneNode(true)", .ex = "undefined" },
        .{ .src = "clone_deep.firstChild.nodeName === '#text'", .ex = "true" },
    };
    try checkCases(js_env, &node_clone);

    var node_contains = [_]Case{
        .{ .src = "link.contains(text)", .ex = "true" },
        .{ .src = "text.contains(link)", .ex = "false" },
    };
    try checkCases(js_env, &node_contains);

    var node_has_child_nodes = [_]Case{
        .{ .src = "link.hasChildNodes()", .ex = "true" },
        .{ .src = "text.hasChildNodes()", .ex = "false" },
    };
    try checkCases(js_env, &node_has_child_nodes);

    var node_insert_before = [_]Case{
        .{ .src = "let insertBefore = document.createElement('a')", .ex = "undefined" },
        .{ .src = "link.insertBefore(insertBefore, text) !== undefined", .ex = "true" },
        .{ .src = "link.firstChild.localName === 'a'", .ex = "true" },
    };
    try checkCases(js_env, &node_insert_before);
}
