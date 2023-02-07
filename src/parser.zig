const std = @import("std");

const c = @cImport({
    @cInclude("../../lexbor/source/lexbor/html/html.h");
});

// Public API
// ----------

// EventTarget

pub const EventTarget = c.lxb_dom_event_target_t;

// Node

pub const Node = c.lxb_dom_node_t;

pub const NodeType = enum(u4) {
    undef,
    element,
    attribute,
    text,
    cdata_section,
    entity_reference,
    entity,
    processing_instruction,
    comment,
    document,
    document_type,
    document_fragment,
    notation,
    last_entry,
};

pub fn nodeEventTarget(node: *Node) *EventTarget {
    return c.lxb_dom_interface_event_target(node);
}

pub const nodeWalker = (fn (node: ?*Node, _: ?*anyopaque) callconv(.C) Action);

pub fn nodeName(node: *Node) [*c]const u8 {
    var s: usize = undefined;
    return c.lxb_dom_node_name(node, &s);
}

pub fn nodeType(node: *Node) NodeType {
    return @intToEnum(NodeType, node.*.type);
}

pub fn nodeWalk(node: *Node, comptime walker: nodeWalker) !void {
    c.lxb_dom_node_simple_walk(node, walker, null);
}

// Element

pub const Element = c.lxb_dom_element_t;

pub fn elementNode(element: *Element) *Node {
    return c.lxb_dom_interface_node(element);
}

pub fn elementLocalName(element: *Element) []const u8 {
    const local_name = c.lxb_dom_element_local_name(element, null);
    return std.mem.sliceTo(local_name, 0);
}

pub fn elementsByAttr(
    element: *Element,
    collection: *Collection,
    attr: []const u8,
    value: []const u8,
    case_sensitve: bool,
) !void {
    const status = c.lxb_dom_elements_by_attr(
        element,
        collection,
        attr.ptr,
        attr.len,
        value.ptr,
        value.len,
        case_sensitve,
    );
    if (status != 0) {
        return error.ElementsByAttr;
    }
}

// DocumentHTML

pub const DocumentHTML = c.lxb_html_document_t;

pub fn documentHTMLInit() *DocumentHTML {
    return c.lxb_html_document_create();
}

pub fn documentHTMLDeinit(document_html: *DocumentHTML) void {
    _ = c.lxb_html_document_destroy(document_html);
}

pub fn documentHTMLParse(document_html: *DocumentHTML, html: []const u8) !void {
    const status = c.lxb_html_document_parse(document_html, html.ptr, html.len - 1);
    if (status != 0) {
        return error.DocumentHTMLParse;
    }
}

pub fn documentHTMLToNode(document_html: *DocumentHTML) *Node {
    return c.lxb_dom_interface_node(document_html);
}

pub fn documentHTMLToDocument(document_html: *DocumentHTML) *Document {
    return &document_html.dom_document;
}

pub fn documentHTMLBody(document_html: *DocumentHTML) *Element {
    return c.lxb_dom_interface_element(document_html.body);
}

// Document

pub const Document = c.lxb_dom_document_t;

// Collection

pub const Collection = c.lxb_dom_collection_t;

pub fn collectionInit(document: *Document, size: usize) *Collection {
    return c.lxb_dom_collection_make(document, size);
}

pub fn collectionDeinit(collection: *Collection) void {
    _ = c.lxb_dom_collection_destroy(collection, true);
}

pub fn collectionElement(collection: *Collection, index: usize) *Element {
    return c.lxb_dom_collection_element(collection, index);
}

// Base

pub const Action = c.lexbor_action_t;

// TODO: use enum?
pub const ActionStop = c.LEXBOR_ACTION_STOP;
pub const ActionNext = c.LEXBOR_ACTION_NEXT;
pub const ActionOk = c.LEXBOR_ACTION_OK;

// Playground
// ----------

fn serialize_callback(_: [*c]const u8, _: usize, _: ?*anyopaque) callconv(.C) c_uint {
    return 0;
}

fn walker_play(nn: ?*c.lxb_dom_node_t, _: ?*anyopaque) callconv(.C) c.lexbor_action_t {
    if (nn == null) {
        return c.LEXBOR_ACTION_STOP;
    }
    const n = nn.?;

    var s: usize = undefined;
    const name = c.lxb_dom_node_name(n, &s);

    std.debug.print("type: {d}, name: {s}\n", .{ n.*.type, name });
    if (n.*.local_name == c.LXB_TAG_A) {
        const element = c.lxb_dom_interface_element(n);
        const attr = element.*.first_attr;
        std.debug.print("link, attr: {any}\n", .{attr.*.upper_name});
    }
    return c.LEXBOR_ACTION_OK;
}

pub fn parse_document() void {
    const html = "<div><a href='foo'>OK</a><p>blah-blah-blah</p></div>";
    const html_len = html.len - 1;

    // parse
    const doc = c.lxb_html_document_create();
    const status_parse = c.lxb_html_document_parse(doc, html, html_len);
    std.debug.print("status parse: {any}\n", .{status_parse});

    // tree
    const document_node = c.lxb_dom_interface_node(doc);
    std.debug.print("document node is empty: {any}\n", .{c.lxb_dom_node_is_empty(document_node)});
    std.debug.print("document node type: {any}\n", .{document_node.*.type});
    std.debug.print("document node name: {any}\n", .{document_node.*.local_name});

    c.lxb_dom_node_simple_walk(document_node, walker_play, null);

    const first_child = c.lxb_dom_node_last_child(document_node);
    if (first_child == null) {
        std.debug.print("hummm is null\n", .{});
    }
    std.debug.print("first child type: {any}\n", .{first_child.*.type});
    std.debug.print("first child name: {any}\n", .{first_child.*.local_name});

    const tt = c.lxb_dom_node_first_child(first_child);
    std.debug.print("tt type: {any}\n", .{tt.*.type});
    std.debug.print("tt name: {any}\n", .{tt.*.local_name});
    std.debug.print("{any}\n", .{c.LXB_DOM_NODE_TYPE_TEXT});

    var s: usize = undefined;
    const tt_name = c.lxb_dom_node_name(tt, &s);
    std.debug.print("tt name: {s}\n", .{tt_name});

    const nn = tt.*.first_child;
    if (nn == null) {
        std.debug.print("is null\n", .{});
    }

    // text
    var text_len: usize = undefined;
    var text = c.lxb_dom_node_text_content(tt, &text_len);
    std.debug.print("size: {d}\n", .{text_len});
    std.debug.print("text: {s}\n", .{text});

    // serialize
    const status_serialize = c.lxb_html_serialize_pretty_tree_cb(
        document_node,
        c.LXB_HTML_SERIALIZE_OPT_UNDEF,
        0,
        serialize_callback,
        null,
    );
    std.debug.print("status serialize: {any}\n", .{status_serialize});

    // destroy
    _ = c.lxb_html_document_destroy(doc);
    // _ = c.lxb_dom_document_destroy_text(first_child.*.owner_document, &text);
    // _ = c.lxb_dom_document_destroy_text(c.lxb_dom_interface_document(document), text);
    std.debug.print("text2: {s}\n", .{text}); // should not work
}
