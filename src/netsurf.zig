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
    acronym = c.DOM_HTML_ELEMENT_TYPE_ACRONYM,
    bgsound = c.DOM_HTML_ELEMENT_TYPE_BGSOUND,
    big = c.DOM_HTML_ELEMENT_TYPE_BIG,
    marquee = c.DOM_HTML_ELEMENT_TYPE_MARQUEE,
    nobr = c.DOM_HTML_ELEMENT_TYPE_NOBR,
    noframes = c.DOM_HTML_ELEMENT_TYPE_NOFRAMES,
    spacer = c.DOM_HTML_ELEMENT_TYPE_SPACER,
    strike = c.DOM_HTML_ELEMENT_TYPE_STRIKE,
    tt = c.DOM_HTML_ELEMENT_TYPE_TT,
    a = c.DOM_HTML_ELEMENT_TYPE_A,
    abbr = c.DOM_HTML_ELEMENT_TYPE_ABBR,
    address = c.DOM_HTML_ELEMENT_TYPE_ADDRESS,
    article = c.DOM_HTML_ELEMENT_TYPE_ARTICLE,
    aside = c.DOM_HTML_ELEMENT_TYPE_ASIDE,
    area = c.DOM_HTML_ELEMENT_TYPE_AREA,
    audio = c.DOM_HTML_ELEMENT_TYPE_AUDIO,
    b = c.DOM_HTML_ELEMENT_TYPE_B,
    bdi = c.DOM_HTML_ELEMENT_TYPE_BDI,
    bdo = c.DOM_HTML_ELEMENT_TYPE_BDO,
    br = c.DOM_HTML_ELEMENT_TYPE_BR,
    base = c.DOM_HTML_ELEMENT_TYPE_BASE,
    body = c.DOM_HTML_ELEMENT_TYPE_BODY,
    button = c.DOM_HTML_ELEMENT_TYPE_BUTTON,
    canvas = c.DOM_HTML_ELEMENT_TYPE_CANVAS,
    center = c.DOM_HTML_ELEMENT_TYPE_CENTER,
    cite = c.DOM_HTML_ELEMENT_TYPE_CITE,
    code = c.DOM_HTML_ELEMENT_TYPE_CODE,
    dd = c.DOM_HTML_ELEMENT_TYPE_DD,
    details = c.DOM_HTML_ELEMENT_TYPE_DETAILS,
    dfn = c.DOM_HTML_ELEMENT_TYPE_DFN,
    dt = c.DOM_HTML_ELEMENT_TYPE_DT,
    dl = c.DOM_HTML_ELEMENT_TYPE_DL,
    dialog = c.DOM_HTML_ELEMENT_TYPE_DIALOG,
    data = c.DOM_HTML_ELEMENT_TYPE_DATA,
    datalist = c.DOM_HTML_ELEMENT_TYPE_DATALIST,
    dir = c.DOM_HTML_ELEMENT_TYPE_DIR,
    div = c.DOM_HTML_ELEMENT_TYPE_DIV,
    embed = c.DOM_HTML_ELEMENT_TYPE_EMBED,
    figcaption = c.DOM_HTML_ELEMENT_TYPE_FIGCAPTION,
    figure = c.DOM_HTML_ELEMENT_TYPE_FIGURE,
    fieldset = c.DOM_HTML_ELEMENT_TYPE_FIELDSET,
    footer = c.DOM_HTML_ELEMENT_TYPE_FOOTER,
    font = c.DOM_HTML_ELEMENT_TYPE_FONT,
    form = c.DOM_HTML_ELEMENT_TYPE_FORM,
    frame = c.DOM_HTML_ELEMENT_TYPE_FRAME,
    frameset = c.DOM_HTML_ELEMENT_TYPE_FRAMESET,
    hr = c.DOM_HTML_ELEMENT_TYPE_HR,
    head = c.DOM_HTML_ELEMENT_TYPE_HEAD,
    header = c.DOM_HTML_ELEMENT_TYPE_HEADER,
    h1 = c.DOM_HTML_ELEMENT_TYPE_H1,
    h2 = c.DOM_HTML_ELEMENT_TYPE_H2,
    h3 = c.DOM_HTML_ELEMENT_TYPE_H3,
    h4 = c.DOM_HTML_ELEMENT_TYPE_H4,
    h5 = c.DOM_HTML_ELEMENT_TYPE_H5,
    h6 = c.DOM_HTML_ELEMENT_TYPE_H6,
    hgroup = c.DOM_HTML_ELEMENT_TYPE_HGROUP,
    html = c.DOM_HTML_ELEMENT_TYPE_HTML,
    i = c.DOM_HTML_ELEMENT_TYPE_I,
    isindex = c.DOM_HTML_ELEMENT_TYPE_ISINDEX,
    iframe = c.DOM_HTML_ELEMENT_TYPE_IFRAME,
    img = c.DOM_HTML_ELEMENT_TYPE_IMG,
    input = c.DOM_HTML_ELEMENT_TYPE_INPUT,
    kbd = c.DOM_HTML_ELEMENT_TYPE_KBD,
    li = c.DOM_HTML_ELEMENT_TYPE_LI,
    label = c.DOM_HTML_ELEMENT_TYPE_LABEL,
    legend = c.DOM_HTML_ELEMENT_TYPE_LEGEND,
    link = c.DOM_HTML_ELEMENT_TYPE_LINK,
    main = c.DOM_HTML_ELEMENT_TYPE_MAIN,
    map = c.DOM_HTML_ELEMENT_TYPE_MAP,
    mark = c.DOM_HTML_ELEMENT_TYPE_MARK,
    meta = c.DOM_HTML_ELEMENT_TYPE_META,
    meter = c.DOM_HTML_ELEMENT_TYPE_METER,
    nav = c.DOM_HTML_ELEMENT_TYPE_NAV,
    noscript = c.DOM_HTML_ELEMENT_TYPE_NOSCRIPT,
    ins = c.DOM_HTML_ELEMENT_TYPE_INS,
    del = c.DOM_HTML_ELEMENT_TYPE_DEL,
    ol = c.DOM_HTML_ELEMENT_TYPE_OL,
    object = c.DOM_HTML_ELEMENT_TYPE_OBJECT,
    optgroup = c.DOM_HTML_ELEMENT_TYPE_OPTGROUP,
    option = c.DOM_HTML_ELEMENT_TYPE_OPTION,
    output = c.DOM_HTML_ELEMENT_TYPE_OUTPUT,
    p = c.DOM_HTML_ELEMENT_TYPE_P,
    param = c.DOM_HTML_ELEMENT_TYPE_PARAM,
    picture = c.DOM_HTML_ELEMENT_TYPE_PICTURE,
    pre = c.DOM_HTML_ELEMENT_TYPE_PRE,
    progress = c.DOM_HTML_ELEMENT_TYPE_PROGRESS,
    blockquote = c.DOM_HTML_ELEMENT_TYPE_BLOCKQUOTE,
    q = c.DOM_HTML_ELEMENT_TYPE_Q,
    rp = c.DOM_HTML_ELEMENT_TYPE_RP,
    rt = c.DOM_HTML_ELEMENT_TYPE_RT,
    ruby = c.DOM_HTML_ELEMENT_TYPE_RUBY,
    s = c.DOM_HTML_ELEMENT_TYPE_S,
    samp = c.DOM_HTML_ELEMENT_TYPE_SAMP,
    section = c.DOM_HTML_ELEMENT_TYPE_SECTION,
    small = c.DOM_HTML_ELEMENT_TYPE_SMALL,
    sub = c.DOM_HTML_ELEMENT_TYPE_SUB,
    summary = c.DOM_HTML_ELEMENT_TYPE_SUMMARY,
    sup = c.DOM_HTML_ELEMENT_TYPE_SUP,
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
    colgroup = c.DOM_HTML_ELEMENT_TYPE_COLGROUP,
    tr = c.DOM_HTML_ELEMENT_TYPE_TR,
    thead = c.DOM_HTML_ELEMENT_TYPE_THEAD,
    tbody = c.DOM_HTML_ELEMENT_TYPE_TBODY,
    tfoot = c.DOM_HTML_ELEMENT_TYPE_TFOOT,
    template = c.DOM_HTML_ELEMENT_TYPE_TEMPLATE,
    textarea = c.DOM_HTML_ELEMENT_TYPE_TEXTAREA,
    time = c.DOM_HTML_ELEMENT_TYPE_TIME,
    title = c.DOM_HTML_ELEMENT_TYPE_TITLE,
    track = c.DOM_HTML_ELEMENT_TYPE_TRACK,
    u = c.DOM_HTML_ELEMENT_TYPE_U,
    ul = c.DOM_HTML_ELEMENT_TYPE_UL,
    _var = c.DOM_HTML_ELEMENT_TYPE_VAR,
    video = c.DOM_HTML_ELEMENT_TYPE_VIDEO,
    wbr = c.DOM_HTML_ELEMENT_TYPE_WBR,
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

// NodeList
pub const NodeList = c.dom_nodelist;

pub fn nodeListLength(nodeList: *NodeList) u32 {
    var ln: u32 = undefined;
    _ = c.dom_nodelist_get_length(nodeList, &ln);
    return ln;
}

pub fn nodeListItem(nodeList: *NodeList, index: u32) ?*Node {
    var n: [*c]c.dom_node = undefined;
    _ = c._dom_nodelist_item(nodeList, index, &n);

    if (n == null) {
        return null;
    }

    // cast [*c]c.dom_node into *Node
    return @as(*Node, @ptrCast(n));
}

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

pub fn nodeNextElementSibling(node: *Node) ?*Element {
    var n = node;
    while (true) {
        const res = nodeNextSibling(n);
        if (res == null) {
            return null;
        }
        if (nodeType(res.?) == .element) {
            return @as(*Element, @ptrCast(res.?));
        }
        n = res.?;
    }
    return null;
}

pub fn nodePreviousSibling(node: *Node) ?*Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_get_previous_sibling.?(node, &res);
    return res;
}

pub fn nodePreviousElementSibling(node: *Node) ?*Element {
    var n = node;
    while (true) {
        const res = nodePreviousSibling(n);
        if (res == null) {
            return null;
        }
        if (nodeType(res.?) == .element) {
            return @as(*Element, @ptrCast(res.?));
        }
        n = res.?;
    }
    return null;
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

pub fn nodeIsEqualNode(node: *Node, other: *Node) bool {
    var res: bool = undefined;
    _ = nodeVtable(node).dom_node_is_equal.?(node, other, &res);
    return res;
}

pub fn nodeIsSameNode(node: *Node, other: *Node) bool {
    var res: bool = undefined;
    _ = nodeVtable(node).dom_node_is_same.?(node, other, &res);
    return res;
}

pub fn nodeLookupPrefix(node: *Node, namespace: []const u8) ?[]const u8 {
    var s: ?*String = undefined;
    _ = nodeVtable(node).dom_node_lookup_prefix.?(node, stringFromData(namespace), &s);
    if (s == null) {
        return null;
    }
    return stringToData(s.?);
}

pub fn nodeLookupNamespaceURI(node: *Node, prefix: ?[]const u8) ?[]const u8 {
    var s: ?*String = undefined;
    _ = nodeVtable(node).dom_node_lookup_namespace.?(node, stringFromData(prefix.?), &s);
    if (s == null) {
        return null;
    }
    return stringToData(s.?);
}

pub fn nodeNormalize(node: *Node) void {
    _ = nodeVtable(node).dom_node_normalize.?(node);
}

pub fn nodeRemoveChild(node: *Node, child: *Node) *Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_remove_child.?(node, child, &res);
    return res.?;
}

pub fn nodeReplaceChild(node: *Node, new_child: *Node, old_child: *Node) *Node {
    var res: ?*Node = undefined;
    _ = nodeVtable(node).dom_node_replace_child.?(node, new_child, old_child, &res);
    return res.?;
}

// CharacterData
pub const CharacterData = c.dom_characterdata;

fn characterDataVtable(data: *CharacterData) c.dom_characterdata_vtable {
    return getVtable(c.dom_characterdata_vtable, CharacterData, data);
}

pub inline fn characterDataToNode(cdata: *CharacterData) *Node {
    return @as(*Node, @ptrCast(cdata));
}

pub fn characterDataData(cdata: *CharacterData) []const u8 {
    var s: ?*String = undefined;
    _ = characterDataVtable(cdata).dom_characterdata_get_data.?(cdata, &s);
    return stringToData(s.?);
}

pub fn characterDataSetData(cdata: *CharacterData, data: []const u8) void {
    const s = stringFromData(data);
    _ = characterDataVtable(cdata).dom_characterdata_set_data.?(cdata, s);
}

pub fn characterDataLength(cdata: *CharacterData) u32 {
    var n: u32 = undefined;
    _ = characterDataVtable(cdata).dom_characterdata_get_length.?(cdata, &n);
    return n;
}

pub fn characterDataAppendData(cdata: *CharacterData, data: []const u8) void {
    const s = stringFromData(data);
    _ = characterDataVtable(cdata).dom_characterdata_append_data.?(cdata, s);
}

pub fn characterDataDeleteData(cdata: *CharacterData, offset: u32, count: u32) void {
    _ = characterDataVtable(cdata).dom_characterdata_delete_data.?(cdata, offset, count);
}

pub fn characterDataInsertData(cdata: *CharacterData, offset: u32, data: []const u8) void {
    const s = stringFromData(data);
    _ = characterDataVtable(cdata).dom_characterdata_insert_data.?(cdata, offset, s);
}

pub fn characterDataReplaceData(cdata: *CharacterData, offset: u32, count: u32, data: []const u8) void {
    const s = stringFromData(data);
    _ = characterDataVtable(cdata).dom_characterdata_replace_data.?(cdata, offset, count, s);
}

pub fn characterDataSubstringData(cdata: *CharacterData, offset: u32, count: u32) []const u8 {
    var s: ?*String = undefined;
    _ = characterDataVtable(cdata).dom_characterdata_substring_data.?(cdata, offset, count, &s);
    return stringToData(s.?);
}

// Text
pub const Text = c.dom_text;

fn textVtable(text: *Text) c.dom_text_vtable {
    return getVtable(c.dom_text_vtable, Text, text);
}

pub fn textWholdeText(text: *Text) []const u8 {
    var s: ?*String = undefined;
    _ = textVtable(text).dom_text_get_whole_text.?(text, &s);
    return stringToData(s.?);
}

pub fn textSplitText(text: *Text, offset: u32) *Text {
    var res: ?*Text = undefined;
    _ = textVtable(text).dom_text_split_text.?(text, offset, &res);
    return res.?;
}

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

pub fn elementGetAttribute(elem: *Element, name: []const u8) ?[]const u8 {
    var s: ?*String = undefined;
    _ = elementVtable(elem).dom_element_get_attribute.?(elem, stringFromData(name), &s);
    if (s == null) {
        return null;
    }
    return stringToData(s.?);
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
pub const DataList = struct { base: *c.dom_html_element };
pub const Dialog = struct { base: *c.dom_html_element };
pub const Directory = struct { base: *c.dom_html_element };
pub const Div = c.dom_html_div_element;
pub const Embed = struct { base: *c.dom_html_element };
pub const FieldSet = c.dom_html_field_set_element;
pub const Form = c.dom_html_form_element;
pub const Font = c.dom_html_font_element;
pub const Frame = c.dom_html_frame_element;
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
pub const Param = c.dom_html_param_element;
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

pub inline fn documentGetElementsByTagName(doc: *Document, tagname: []const u8) *NodeList {
    var nlist: ?*NodeList = undefined;
    _ = documentVtable(doc).dom_document_get_elements_by_tag_name.?(doc, stringFromData(tagname), &nlist);
    return nlist.?;
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

// documentHTMLParseFromFileAlloc parses the file.
// The allocator is required to create a null terminated string from filename.
// The buffer is freed by the function.
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromFileAlloc(allocator: std.mem.Allocator, filename: []const u8) !*DocumentHTML {
    const cstr = try allocator.dupeZ(u8, filename);
    defer allocator.free(cstr);

    return documentHTMLParseFromFile(cstr);
}

// documentHTMLParseFromFile parses the given filename c string (ie. with 0 sentinel).
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromFile(filename: [:0]const u8) !*DocumentHTML {
    // create a null terminated c string.
    const doc = c.wr_create_doc_dom_from_file(filename.ptr);
    if (doc == null) {
        return error.ParserError;
    }
    return @as(*DocumentHTML, @ptrCast(doc.?));
}

// documentHTMLParseFromStrAlloc the given string.
// The allocator is required to create a null terminated string.
// The c string allocated is freed by the function.
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromStrAlloc(allocator: std.mem.Allocator, str: [:0]const u8) !*DocumentHTML {
    // create a null terminated c string.
    const cstr = try allocator.dupeZ(u8, str);
    defer allocator.free(cstr);

    return documentHTMLParseFromStr(cstr);
}

// documentHTMLParseFromStr parses the given c string (ie. with 0 sentinel).
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromStr(cstr: [:0]const u8) !*DocumentHTML {
    const doc = c.wr_create_doc_dom_from_string(cstr.ptr);
    if (doc == null) {
        return error.ParserError;
    }
    return @as(*DocumentHTML, @ptrCast(doc.?));
}

// documentHTMLClose closes the document.
pub fn documentHTMLClose(doc: *DocumentHTML) void {
    _ = documentHTMLVtable(doc).close.?(doc);
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
