const std = @import("std");

const c = @cImport({
    @cInclude("wrapper.h");
});

// Vtable
// ------

// netsurf libdom is using a vtable mechanism to handle the DOM tree heritage.
// The vtable allow to select, from a parent, the right implementation of a
// function for the child.

// For example let's consider the following implementations of Node:
// - Node <- CharacterData <- Text
// - Node <- Element <- HTMLElement <- HTMLDivElement
// If we take the `textContent` getter function on Node, the W3C standard says
// that the result depends on the interface the Node implements, so
// Node.textContent will be different depending if Node implements a Text or an
// HTMLDivElement.
// To handle that libdom provides a function on the child interface that
// "override" the default parent function.
// In this case there is a function dom_characterdata_get_text_content who
// "override" parent function dom_node_get_text_content.
// Like in an object-oriented language with heritage.
// A vtable is attached to each "object" to retrieve the corresponding function.

// NOTE: we can't use the high-level functions of libdom public API to get the
// vtable as the public API defines only empty structs for each DOM interface,
// which are translated by Zig as *const anyopaque with unknown alignement
// (ie. 1), which leads to a compile error as the underling type is bigger.

// So we need to use this obscure function to retrieve the vtable, making the
// appropriate alignCast to ensure alignment.
// This function is meant to be used by each DOM interface (Node, Document, etc)
// Parameters:
// - VtableT: the type of the vtable (dom_node_vtable, dom_element_vtable, etc)
// - NodeT: the type of the node interface (dom_element, dom_document, etc)
// - node: the node interface instance
inline fn getVtable(comptime VtableT: type, comptime NodeT: type, node: anytype) VtableT {
    // first align correctly the node interface
    const node_aligned: *align(@alignOf([*c]c.dom_node)) NodeT = @alignCast(node);
    // then convert the node interface to a base node
    const node_base = @as([*c]c.dom_node, @ptrCast(node_aligned));

    // retrieve the vtable on the base node
    const vtable = node_base.*.vtable.?;
    // align correctly the vtable
    const vtable_aligned: *align(@alignOf([*c]VtableT)) const anyopaque = @alignCast(vtable);
    // convert the vtable to it's actual type and return it
    return @as([*c]const VtableT, @ptrCast(vtable_aligned)).*;
}

// Utils
const String = c.dom_string;

inline fn stringToData(s: *String) []const u8 {
    const data = c.dom_string_data(s);
    return data[0..c.dom_string_byte_length(s)];
}

inline fn stringFromData(data: []const u8) *String {
    var s: ?*String = undefined;
    _ = c.dom_string_create(data.ptr, data.len, &s);
    return s.?;
}

// Tag

pub const Tag = enum(u8) {
    a = c.DOM_HTML_ELEMENT_TYPE_A,
    area = c.DOM_HTML_ELEMENT_TYPE_AREA,
    audio = c.DOM_HTML_ELEMENT_TYPE_AUDIO,
    br = c.DOM_HTML_ELEMENT_TYPE_BR,
    base = c.DOM_HTML_ELEMENT_TYPE_BASE,
    body = c.DOM_HTML_ELEMENT_TYPE_BODY,
    button = c.DOM_HTML_ELEMENT_TYPE_BUTTON,
    canvas = c.DOM_HTML_ELEMENT_TYPE_CANVAS,
    dl = c.DOM_HTML_ELEMENT_TYPE_DL,
    dialog = c.DOM_HTML_ELEMENT_TYPE_DIALOG,
    data = c.DOM_HTML_ELEMENT_TYPE_DATA,
    div = c.DOM_HTML_ELEMENT_TYPE_DIV,
    embed = c.DOM_HTML_ELEMENT_TYPE_EMBED,
    fieldset = c.DOM_HTML_ELEMENT_TYPE_FIELDSET,
    form = c.DOM_HTML_ELEMENT_TYPE_FORM,
    frameset = c.DOM_HTML_ELEMENT_TYPE_FRAMESET,
    hr = c.DOM_HTML_ELEMENT_TYPE_HR,
    head = c.DOM_HTML_ELEMENT_TYPE_HEAD,
    h1 = c.DOM_HTML_ELEMENT_TYPE_H1,
    h2 = c.DOM_HTML_ELEMENT_TYPE_H2,
    h3 = c.DOM_HTML_ELEMENT_TYPE_H3,
    h4 = c.DOM_HTML_ELEMENT_TYPE_H4,
    h5 = c.DOM_HTML_ELEMENT_TYPE_H5,
    h6 = c.DOM_HTML_ELEMENT_TYPE_H6,
    html = c.DOM_HTML_ELEMENT_TYPE_HTML,
    iframe = c.DOM_HTML_ELEMENT_TYPE_IFRAME,
    img = c.DOM_HTML_ELEMENT_TYPE_IMG,
    input = c.DOM_HTML_ELEMENT_TYPE_INPUT,
    li = c.DOM_HTML_ELEMENT_TYPE_LI,
    label = c.DOM_HTML_ELEMENT_TYPE_LABEL,
    legend = c.DOM_HTML_ELEMENT_TYPE_LEGEND,
    link = c.DOM_HTML_ELEMENT_TYPE_LINK,
    map = c.DOM_HTML_ELEMENT_TYPE_MAP,
    meta = c.DOM_HTML_ELEMENT_TYPE_META,
    meter = c.DOM_HTML_ELEMENT_TYPE_METER,
    ins = c.DOM_HTML_ELEMENT_TYPE_INS,
    del = c.DOM_HTML_ELEMENT_TYPE_DEL,
    ol = c.DOM_HTML_ELEMENT_TYPE_OL,
    object = c.DOM_HTML_ELEMENT_TYPE_OBJECT,
    optgroup = c.DOM_HTML_ELEMENT_TYPE_OPTGROUP,
    option = c.DOM_HTML_ELEMENT_TYPE_OPTION,
    output = c.DOM_HTML_ELEMENT_TYPE_OUTPUT,
    p = c.DOM_HTML_ELEMENT_TYPE_P,
    picture = c.DOM_HTML_ELEMENT_TYPE_PICTURE,
    pre = c.DOM_HTML_ELEMENT_TYPE_PRE,
    progress = c.DOM_HTML_ELEMENT_TYPE_PROGRESS,
    blockquote = c.DOM_HTML_ELEMENT_TYPE_BLOCKQUOTE,
    q = c.DOM_HTML_ELEMENT_TYPE_Q,
    script = c.DOM_HTML_ELEMENT_TYPE_SCRIPT,
    select = c.DOM_HTML_ELEMENT_TYPE_SELECT,
    source = c.DOM_HTML_ELEMENT_TYPE_SOURCE,
    span = c.DOM_HTML_ELEMENT_TYPE_SPAN,
    style = c.DOM_HTML_ELEMENT_TYPE_STYLE,
    table = c.DOM_HTML_ELEMENT_TYPE_TABLE,
    caption = c.DOM_HTML_ELEMENT_TYPE_CAPTION,
    th = c.DOM_HTML_ELEMENT_TYPE_TH,
    td = c.DOM_HTML_ELEMENT_TYPE_TD,
    col = c.DOM_HTML_ELEMENT_TYPE_COL,
    tr = c.DOM_HTML_ELEMENT_TYPE_TR,
    thead = c.DOM_HTML_ELEMENT_TYPE_THEAD,
    tbody = c.DOM_HTML_ELEMENT_TYPE_TBODY,
    tfoot = c.DOM_HTML_ELEMENT_TYPE_TFOOT,
    template = c.DOM_HTML_ELEMENT_TYPE_TEMPLATE,
    textarea = c.DOM_HTML_ELEMENT_TYPE_TEXTAREA,
    time = c.DOM_HTML_ELEMENT_TYPE_TIME,
    title = c.DOM_HTML_ELEMENT_TYPE_TITLE,
    track = c.DOM_HTML_ELEMENT_TYPE_TRACK,
    ul = c.DOM_HTML_ELEMENT_TYPE_UL,
    video = c.DOM_HTML_ELEMENT_TYPE_VIDEO,
    undef = c.DOM_HTML_ELEMENT_TYPE__UNKNOWN,

    pub fn all() []Tag {
        comptime {
            const info = @typeInfo(Tag).Enum;
            comptime var l: [info.fields.len]Tag = undefined;
            inline for (info.fields, 0..) |field, i| {
                l[i] = @as(Tag, @enumFromInt(field.value));
            }
            return &l;
        }
    }

    pub fn allElements() [][]const u8 {
        comptime {
            const tags = all();
            var names: [tags.len][]const u8 = undefined;
            inline for (tags, 0..) |tag, i| {
                names[i] = tag.elementName();
            }
            return &names;
        }
    }

    fn upperName(comptime name: []const u8) []const u8 {
        comptime {
            var upper_name: [name.len]u8 = undefined;
            for (name, 0..) |char, i| {
                var to_upper = false;
                if (i == 0) {
                    to_upper = true;
                } else if (i == 1 and name.len == 2) {
                    to_upper = true;
                }
                if (to_upper) {
                    upper_name[i] = std.ascii.toUpper(char);
                } else {
                    upper_name[i] = char;
                }
            }
            return &upper_name;
        }
    }

    fn elementName(comptime tag: Tag) []const u8 {
        return switch (tag) {
            .a => "Anchor",
            .dl => "DList",
            .fieldset => "FieldSet",
            .frameset => "FrameSet",
            .h1, .h2, .h3, .h4, .h5, .h6 => "Heading",
            .iframe => "IFrame",
            .img => "Image",
            .ins, .del => "Mod",
            .ol => "OList",
            .optgroup => "OptGroup",
            .p => "Paragraph",
            .blockquote, .q => "Quote",
            .caption => "TableCaption",
            .th, .td => "TableCell",
            .col => "TableCol",
            .tr => "TableRow",
            .thead, .tbody, .tfoot => "TableSection",
            .textarea => "TextArea",
            .ul => "UList",
            .undef => "Unknown",
            else => upperName(@tagName(tag)),
        };
    }
};

// EventTarget
pub const EventTarget = c.dom_event_target;

// NodeType

pub const NodeType = enum(u4) {
    element = c.DOM_ELEMENT_NODE,
    attribute = c.DOM_ATTRIBUTE_NODE,
    text = c.DOM_TEXT_NODE,
    cdata_section = c.DOM_CDATA_SECTION_NODE,
    entity_reference = c.DOM_ENTITY_REFERENCE_NODE, // historical
    entity = c.DOM_ENTITY_NODE, // historical
    processing_instruction = c.DOM_PROCESSING_INSTRUCTION_NODE,
    comment = c.DOM_COMMENT_NODE,
    document = c.DOM_DOCUMENT_NODE,
    document_type = c.DOM_DOCUMENT_TYPE_NODE,
    document_fragment = c.DOM_DOCUMENT_FRAGMENT_NODE,
    notation = c.DOM_NOTATION_NODE, // historical
};

// Node
pub const Node = c.dom_node_internal;

fn nodeVtable(node: *Node) c.dom_node_vtable {
    return getVtable(c.dom_node_vtable, Node, node);
}

pub fn nodeLocalName(node: *Node) []const u8 {
    var s: ?*String = undefined;
    _ = nodeVtable(node).dom_node_get_local_name.?(node, &s);
    var s_lower: ?*String = undefined;
    _ = c.dom_string_tolower(s, true, &s_lower);
    return stringToData(s_lower.?);
}

pub fn nodeType(node: *Node) NodeType {
    var node_type: c.dom_node_type = undefined;
    _ = nodeVtable(node).dom_node_get_node_type.?(node, &node_type);
    return @as(NodeType, @enumFromInt(node_type));
}

pub fn nodeFirstChild(node: *Node) ?*Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_get_first_child.?(node, &res);
    return res;
}

pub fn nodeLastChild(node: *Node) ?*Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_get_last_child.?(node, &res);
    return res;
}

pub fn nodeNextSibling(node: *Node) ?*Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_get_next_sibling.?(node, &res);
    return res;
}

pub fn nodePreviousSibling(node: *Node) ?*Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_get_previous_sibling.?(node, &res);
    return res;
}

pub fn nodeParentNode(node: *Node) ?*Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_get_parent_node.?(node, &res);
    return res;
}

pub fn nodeParentElement(node: *Node) ?*Element {
    const res = nodeParentNode(node);
    if (res) |value| {
        if (nodeType(value) == .element) {
            return @as(*Element, @ptrCast(value));
        }
    }
    return null;
}

pub fn nodeName(node: *Node) []const u8 {
    var s: ?*String = undefined;
    _ = nodeVtable(node).dom_node_get_node_name.?(node, &s);
    return stringToData(s.?);
}

pub fn nodeOwnerDocument(node: *Node) ?*Document {
    var doc: ?*Document = undefined;
    _ = nodeVtable(node).dom_node_get_owner_document.?(node, &doc);
    return doc;
}

pub fn nodeValue(node: *Node) ?[]const u8 {
    var s: ?*String = undefined;
    _ = nodeVtable(node).dom_node_get_node_value.?(node, &s);
    if (s == null) {
        return null;
    }
    return stringToData(s.?);
}

pub fn nodeSetValue(node: *Node, value: []const u8) void {
    const s = stringFromData(value);
    _ = nodeVtable(node).dom_node_set_node_value.?(node, s);
}

pub fn nodeTextContent(node: *Node) ?[]const u8 {
    var s: ?*String = undefined;
    _ = nodeVtable(node).dom_node_get_text_content.?(node, &s);
    if (s == null) {
        // NOTE: it seems that there is a bug in netsurf implem
        // an empty Element should return an empty string and not null
        if (nodeType(node) == .element) {
            return "";
        }
        return null;
    }
    return stringToData(s.?);
}

pub fn nodeSetTextContent(node: *Node, value: []const u8) void {
    const s = stringFromData(value);
    _ = nodeVtable(node).dom_node_set_text_content.?(node, s);
}

pub fn nodeAppendChild(node: *Node, child: *Node) *Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_append_child.?(node, child, &res);
    return res.?;
}

pub fn nodeCloneNode(node: *Node, is_deep: bool) *Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_clone_node.?(node, is_deep, &res);
    return res.?;
}

pub fn nodeContains(node: *Node, other: *Node) bool {
    var res: bool = undefined;
    _ = c._dom_node_contains(node, other, &res);
    return res;
}

pub fn nodeHasChildNodes(node: *Node) bool {
    var res: bool = undefined;
    _ = nodeVtable(node).dom_node_has_child_nodes.?(node, &res);
    return res;
}

pub fn nodeInsertBefore(node: *Node, new_node: *Node, ref_node: *Node) *Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_insert_before.?(node, new_node, ref_node, &res);
    return res.?;
}

pub fn nodeIsDefaultNamespace(node: *Node, namespace: []const u8) bool {
    const s = stringFromData(namespace);
    var res: bool = undefined;
    _ = nodeVtable(node).dom_node_is_default_namespace.?(node, s, &res);
    return res;
}

// CharacterData
pub const CharacterData = c.dom_characterdata;

// Text
pub const Text = c.dom_text;

// Comment
pub const Comment = c.dom_comment;

// Element
pub const Element = c.dom_element;

fn elementVtable(elem: *Element) c.dom_element_vtable {
    return getVtable(c.dom_element_vtable, Element, elem);
}

pub fn elementLocalName(elem: *Element) []const u8 {
    const node = @as(*Node, @ptrCast(elem));
    return nodeLocalName(node);
}

// ElementHTML
pub const ElementHTML = c.dom_html_element;

fn elementHTMLVtable(elem_html: *ElementHTML) c.dom_html_element_vtable {
    return getVtable(c.dom_html_element_vtable, ElementHTML, elem_html);
}

pub fn elementHTMLGetTagType(elem_html: *ElementHTML) Tag {
    var tag_type: c.dom_html_element_type = undefined;
    _ = elementHTMLVtable(elem_html).dom_html_element_get_tag_type.?(elem_html, &tag_type);
    return @as(Tag, @enumFromInt(tag_type));
}

// ElementsHTML

pub const MediaElement = struct { base: *c.dom_html_element };

pub const Unknown = struct { base: *c.dom_html_element };
pub const Anchor = c.dom_html_anchor_element;
pub const Area = c.dom_html_area_element;
pub const Audio = struct { base: *c.dom_html_element };
pub const BR = c.dom_html_br_element;
pub const Base = c.dom_html_base_element;
pub const Body = c.dom_html_body_element;
pub const Button = c.dom_html_button_element;
pub const Canvas = c.dom_html_canvas_element;
pub const DList = c.dom_html_dlist_element;
pub const Data = struct { base: *c.dom_html_element };
pub const Dialog = struct { base: *c.dom_html_element };
pub const Div = c.dom_html_div_element;
pub const Embed = struct { base: *c.dom_html_element };
pub const FieldSet = c.dom_html_field_set_element;
pub const Form = c.dom_html_form_element;
pub const FrameSet = c.dom_html_frame_set_element;
pub const HR = c.dom_html_hr_element;
pub const Head = c.dom_html_head_element;
pub const Heading = c.dom_html_heading_element;
pub const Html = c.dom_html_html_element;
pub const IFrame = c.dom_html_iframe_element;
pub const Image = c.dom_html_image_element;
pub const Input = c.dom_html_input_element;
pub const LI = c.dom_html_li_element;
pub const Label = c.dom_html_label_element;
pub const Legend = c.dom_html_legend_element;
pub const Link = c.dom_html_link_element;
pub const Map = c.dom_html_map_element;
pub const Meta = c.dom_html_meta_element;
pub const Meter = struct { base: *c.dom_html_element };
pub const Mod = c.dom_html_mod_element;
pub const OList = c.dom_html_olist_element;
pub const Object = c.dom_html_object_element;
pub const OptGroup = c.dom_html_opt_group_element;
pub const Option = c.dom_html_option_element;
pub const Output = struct { base: *c.dom_html_element };
pub const Paragraph = c.dom_html_paragraph_element;
pub const Picture = struct { base: *c.dom_html_element };
pub const Pre = c.dom_html_pre_element;
pub const Progress = struct { base: *c.dom_html_element };
pub const Quote = c.dom_html_quote_element;
pub const Script = c.dom_html_script_element;
pub const Select = c.dom_html_select_element;
pub const Source = struct { base: *c.dom_html_element };
pub const Span = struct { base: *c.dom_html_element };
pub const Style = c.dom_html_style_element;
pub const Table = c.dom_html_table_element;
pub const TableCaption = c.dom_html_table_caption_element;
pub const TableCell = c.dom_html_table_cell_element;
pub const TableCol = c.dom_html_table_col_element;
pub const TableRow = c.dom_html_table_row_element;
pub const TableSection = c.dom_html_table_section_element;
pub const Template = struct { base: *c.dom_html_element };
pub const TextArea = c.dom_html_text_area_element;
pub const Time = struct { base: *c.dom_html_element };
pub const Title = c.dom_html_title_element;
pub const Track = struct { base: *c.dom_html_element };
pub const UList = c.dom_html_u_list_element;
pub const Video = struct { base: *c.dom_html_element };

// Document Position

pub const DocumentPosition = enum(u2) {
    disconnected = c.DOM_DOCUMENT_POSITION_DISCONNECTED,
    preceding = c.DOM_DOCUMENT_POSITION_PRECEDING,
    following = c.DOM_DOCUMENT_POSITION_FOLLOWING,
    contains = c.DOM_DOCUMENT_POSITION_CONTAINS,
    contained_by = c.DOM_DOCUMENT_POSITION_CONTAINED_BY,
    implementation_specific = c.DOM_DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC,
};

// Document
pub const Document = c.dom_document;

fn documentVtable(doc: *Document) c.dom_document_vtable {
    return getVtable(c.dom_document_vtable, Document, doc);
}

pub inline fn documentGetElementById(doc: *Document, id: []const u8) ?*Element {
    var elem: ?*Element = undefined;
    _ = documentVtable(doc).dom_document_get_element_by_id.?(doc, stringFromData(id), &elem);
    return elem;
}

pub inline fn documentCreateElement(doc: *Document, tag_name: []const u8) *Element {
    var elem: ?*Element = undefined;
    _ = documentVtable(doc).dom_document_create_element.?(doc, stringFromData(tag_name), &elem);
    return elem.?;
}

// DocumentHTML
pub const DocumentHTML = c.dom_html_document;

fn documentHTMLVtable(doc_html: *DocumentHTML) c.dom_html_document_vtable {
    return getVtable(c.dom_html_document_vtable, DocumentHTML, doc_html);
}

pub fn documentHTMLParse(filename: []u8) *DocumentHTML {
    const doc = c.wr_create_doc_dom_from_file(filename.ptr);
    if (doc == null) {
        @panic("error parser");
    }
    return @as(*DocumentHTML, @ptrCast(doc.?));
}

pub inline fn documentHTMLToDocument(doc_html: *DocumentHTML) *Document {
    return @as(*Document, @ptrCast(doc_html));
}

pub inline fn documentHTMLBody(doc_html: *DocumentHTML) ?*Body {
    var body: ?*ElementHTML = undefined;
    _ = documentHTMLVtable(doc_html).get_body.?(doc_html, &body);
    if (body == null) {
        return null;
    }
    return @as(*Body, @ptrCast(body.?));
}
