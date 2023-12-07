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
    const node_aligned: *align(@alignOf(NodeExternal)) NodeT = @alignCast(node);
    // then convert the node interface to a base node
    const node_base = @as(NodeExternal, @ptrCast(node_aligned));

    // retrieve the vtable on the base node
    const vtable = node_base.*.vtable.?;
    // align correctly the vtable
    const vtable_aligned: *align(@alignOf([*c]VtableT)) const anyopaque = @alignCast(vtable);
    // convert the vtable to it's actual type and return it
    return @as([*c]const VtableT, @ptrCast(vtable_aligned)).*;
}

// Utils
const String = c.dom_string;

inline fn strToData(s: *String) []const u8 {
    const data = c.dom_string_data(s);
    return data[0..c.dom_string_byte_length(s)];
}

inline fn strFromData(data: []const u8) !*String {
    var s: ?*String = undefined;
    const err = c.dom_string_create(data.ptr, data.len, &s);
    try DOMErr(err);
    return s.?;
}

const LWCString = c.lwc_string;

// TODO implement lwcStringToData
// inline fn lwcStringToData(s: *LWCString) []const u8 {
// }

inline fn lwcStringFromData(data: []const u8) !*LWCString {
    var s: ?*LWCString = undefined;
    const err = c.lwc_intern_string(data.ptr, data.len, &s);
    try DOMErr(err);
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

// DOMException

pub const DOMError = error{
    NoError,
    IndexSize,
    StringSize,
    HierarchyRequest,
    WrongDocument,
    InvalidCharacter,
    NoDataAllowed,
    NoModificationAllowed,
    NotFound,
    NotSupported,
    InuseAttribute,
    InvalidState,
    Syntax,
    InvalidModification,
    Namespace,
    InvalidAccess,
    Validation,
    TypeMismatch,
    Security,
    Network,
    Abort,
    URLismatch,
    QuotaExceeded,
    Timeout,
    InvalidNodeType,
    DataClone,
};

const DOMException = c.dom_exception;

fn DOMErr(except: DOMException) DOMError!void {
    return switch (except) {
        c.DOM_NO_ERR => return,
        c.DOM_INDEX_SIZE_ERR => DOMError.IndexSize,
        c.DOM_DOMSTRING_SIZE_ERR => DOMError.StringSize,
        c.DOM_HIERARCHY_REQUEST_ERR => DOMError.HierarchyRequest,
        c.DOM_WRONG_DOCUMENT_ERR => DOMError.WrongDocument,
        c.DOM_INVALID_CHARACTER_ERR => DOMError.InvalidCharacter,
        c.DOM_NO_DATA_ALLOWED_ERR => DOMError.NoDataAllowed,
        c.DOM_NO_MODIFICATION_ALLOWED_ERR => DOMError.NoModificationAllowed,
        c.DOM_NOT_FOUND_ERR => DOMError.NotFound,
        c.DOM_NOT_SUPPORTED_ERR => DOMError.NotSupported,
        c.DOM_INUSE_ATTRIBUTE_ERR => DOMError.InuseAttribute,
        c.DOM_INVALID_STATE_ERR => DOMError.InvalidState,
        c.DOM_SYNTAX_ERR => DOMError.Syntax,
        c.DOM_INVALID_MODIFICATION_ERR => DOMError.InvalidModification,
        c.DOM_NAMESPACE_ERR => DOMError.Namespace,
        c.DOM_INVALID_ACCESS_ERR => DOMError.InvalidAccess,
        c.DOM_VALIDATION_ERR => DOMError.Validation,
        c.DOM_TYPE_MISMATCH_ERR => DOMError.TypeMismatch,
        else => unreachable,
    };
}

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

pub fn nodeListLength(nodeList: *NodeList) !u32 {
    var ln: u32 = undefined;
    const err = c.dom_nodelist_get_length(nodeList, &ln);
    try DOMErr(err);
    return ln;
}

pub fn nodeListItem(nodeList: *NodeList, index: u32) !?*Node {
    var n: NodeExternal = undefined;
    const err = c._dom_nodelist_item(nodeList, index, &n);
    try DOMErr(err);
    if (n == null) return null;
    return @as(*Node, @ptrCast(n));
}

// NodeExternal is the libdom public representation of a Node.
// Since we use the internal representation (dom_node_internal), we declare
// here a private version useful for some netsurf function call.
const NodeExternal = [*c]c.dom_node;

// Convert a parser pointer to a NodeExternal pointer.
fn toNodeExternal(comptime T: type, v: *T) NodeExternal {
    const v_aligned: *align(@alignOf(NodeExternal)) T = @alignCast(v);
    return @ptrCast(v_aligned);
}

// NamedNodeMap
pub const NamedNodeMap = c.dom_namednodemap;

pub fn namedNodeMapGetLength(nnm: *NamedNodeMap) !u32 {
    var ln: u32 = undefined;
    const err = c.dom_namednodemap_get_length(nnm, &ln);
    try DOMErr(err);
    return ln;
}

pub fn namedNodeMapItem(nnm: *NamedNodeMap, index: u32) !?*Attribute {
    var n: NodeExternal = undefined;
    const err = c._dom_namednodemap_item(nnm, index, &n);
    try DOMErr(err);
    if (n == null) return null;

    return @as(*Attribute, @ptrCast(n));
}

pub fn namedNodeMapGetNamedItem(nnm: *NamedNodeMap, qname: []const u8) !?*Attribute {
    var n: NodeExternal = undefined;
    const err = c._dom_namednodemap_get_named_item(nnm, try strFromData(qname), &n);
    try DOMErr(err);
    if (n == null) return null;
    return @as(*Attribute, @ptrCast(n));
}

pub fn namedNodeMapGetNamedItemNS(
    nnm: *NamedNodeMap,
    namespace: []const u8,
    localname: []const u8,
) !?*Attribute {
    var n: NodeExternal = undefined;
    const err = c._dom_namednodemap_get_named_item_ns(
        nnm,
        try strFromData(namespace),
        try strFromData(localname),
        &n,
    );
    try DOMErr(err);
    if (n == null) return null;
    return @as(*Attribute, @ptrCast(n));
}

pub fn namedNodeMapSetNamedItem(nnm: *NamedNodeMap, attr: *Attribute) !?*Attribute {
    var n: NodeExternal = undefined;
    const err = c._dom_namednodemap_set_named_item(
        nnm,
        toNodeExternal(Attribute, attr),
        &n,
    );
    try DOMErr(err);
    if (n == null) return null;
    return @as(*Attribute, @ptrCast(n));
}

pub fn namedNodeMapSetNamedItemNS(nnm: *NamedNodeMap, attr: *Attribute) !?*Attribute {
    var n: NodeExternal = undefined;
    const err = c._dom_namednodemap_set_named_item_ns(
        nnm,
        toNodeExternal(Attribute, attr),
        &n,
    );
    try DOMErr(err);
    if (n == null) return null;
    return @as(*Attribute, @ptrCast(n));
}

pub fn namedNodeMapRemoveNamedItem(nnm: *NamedNodeMap, qname: []const u8) !*Attribute {
    var n: NodeExternal = undefined;
    const err = c._dom_namednodemap_remove_named_item(nnm, try strFromData(qname), &n);
    try DOMErr(err);
    return @as(*Attribute, @ptrCast(n));
}

pub fn namedNodeMapRemoveNamedItemNS(
    nnm: *NamedNodeMap,
    namespace: []const u8,
    localname: []const u8,
) !*Attribute {
    var n: NodeExternal = undefined;
    const err = c._dom_namednodemap_remove_named_item_ns(
        nnm,
        try strFromData(namespace),
        try strFromData(localname),
        &n,
    );
    try DOMErr(err);
    return @as(*Attribute, @ptrCast(n));
}

// Node
pub const Node = c.dom_node_internal;

fn nodeVtable(node: *Node) c.dom_node_vtable {
    return getVtable(c.dom_node_vtable, Node, node);
}

pub fn nodeLocalName(node: *Node) ![]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_get_local_name.?(node, &s);
    try DOMErr(err);
    var s_lower: ?*String = undefined;
    const errStr = c.dom_string_tolower(s, true, &s_lower);
    try DOMErr(errStr);
    return strToData(s_lower.?);
}

pub fn nodeType(node: *Node) !NodeType {
    var node_type: c.dom_node_type = undefined;
    const err = nodeVtable(node).dom_node_get_node_type.?(node, &node_type);
    try DOMErr(err);
    return @as(NodeType, @enumFromInt(node_type));
}

pub fn nodeFirstChild(node: *Node) !?*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_get_first_child.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeLastChild(node: *Node) !?*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_get_last_child.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeNextSibling(node: *Node) !?*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_get_next_sibling.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeNextElementSibling(node: *Node) !?*Element {
    var n = node;
    while (true) {
        const res = try nodeNextSibling(n);
        if (res == null) return null;

        if (try nodeType(res.?) == .element) {
            return @as(*Element, @ptrCast(res.?));
        }
        n = res.?;
    }
    return null;
}

pub fn nodePreviousSibling(node: *Node) !?*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_get_previous_sibling.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodePreviousElementSibling(node: *Node) !?*Element {
    var n = node;
    while (true) {
        const res = try nodePreviousSibling(n);
        if (res == null) return null;

        if (try nodeType(res.?) == .element) {
            return @as(*Element, @ptrCast(res.?));
        }
        n = res.?;
    }
    return null;
}

pub fn nodeParentNode(node: *Node) !?*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_get_parent_node.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeParentElement(node: *Node) !?*Element {
    const res = try nodeParentNode(node);
    if (res) |value| {
        if (try nodeType(value) == .element) {
            return @as(*Element, @ptrCast(value));
        }
    }
    return null;
}

pub fn nodeName(node: *Node) ![]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_get_node_name.?(node, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn nodeOwnerDocument(node: *Node) !?*Document {
    var doc: ?*Document = undefined;
    const err = nodeVtable(node).dom_node_get_owner_document.?(node, &doc);
    try DOMErr(err);
    return doc;
}

pub fn nodeValue(node: *Node) !?[]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_get_node_value.?(node, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeSetValue(node: *Node, value: []const u8) !void {
    const s = try strFromData(value);
    const err = nodeVtable(node).dom_node_set_node_value.?(node, s);
    try DOMErr(err);
}

pub fn nodeTextContent(node: *Node) !?[]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_get_text_content.?(node, &s);
    try DOMErr(err);
    if (s == null) {
        // NOTE: it seems that there is a bug in netsurf implem
        // an empty Element should return an empty string and not null
        if (try nodeType(node) == .element) {
            return "";
        }
        return null;
    }
    return strToData(s.?);
}

pub fn nodeSetTextContent(node: *Node, value: []const u8) !void {
    const s = try strFromData(value);
    const err = nodeVtable(node).dom_node_set_text_content.?(node, s);
    try DOMErr(err);
}

pub fn nodeAppendChild(node: *Node, child: *Node) !*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_append_child.?(node, child, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeCloneNode(node: *Node, is_deep: bool) !*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_clone_node.?(node, is_deep, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeContains(node: *Node, other: *Node) !bool {
    var res: bool = undefined;
    const err = c._dom_node_contains(node, other, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeHasChildNodes(node: *Node) !bool {
    var res: bool = undefined;
    const err = nodeVtable(node).dom_node_has_child_nodes.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeInsertBefore(node: *Node, new_node: *Node, ref_node: *Node) !*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_insert_before.?(node, new_node, ref_node, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeIsDefaultNamespace(node: *Node, namespace: []const u8) !bool {
    const s = try strFromData(namespace);
    var res: bool = undefined;
    const err = nodeVtable(node).dom_node_is_default_namespace.?(node, s, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeIsEqualNode(node: *Node, other: *Node) !bool {
    var res: bool = undefined;
    const err = nodeVtable(node).dom_node_is_equal.?(node, other, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeIsSameNode(node: *Node, other: *Node) !bool {
    var res: bool = undefined;
    const err = nodeVtable(node).dom_node_is_same.?(node, other, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeLookupPrefix(node: *Node, namespace: []const u8) !?[]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_lookup_prefix.?(node, try strFromData(namespace), &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeLookupNamespaceURI(node: *Node, prefix: ?[]const u8) !?[]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_lookup_namespace.?(node, try strFromData(prefix.?), &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeNormalize(node: *Node) !void {
    const err = nodeVtable(node).dom_node_normalize.?(node);
    try DOMErr(err);
}

pub fn nodeRemoveChild(node: *Node, child: *Node) !*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_remove_child.?(node, child, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeReplaceChild(node: *Node, new_child: *Node, old_child: *Node) !*Node {
    var res: ?*Node = undefined;
    const err = nodeVtable(node).dom_node_replace_child.?(node, new_child, old_child, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeHasAttributes(node: *Node) !bool {
    var res: bool = undefined;
    const err = nodeVtable(node).dom_node_has_attributes.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeGetAttributes(node: *Node) !*NamedNodeMap {
    var res: ?*NamedNodeMap = undefined;
    const err = nodeVtable(node).dom_node_get_attributes.?(node, &res);
    try DOMErr(err);
    return res.?;
}

// nodeToElement is an helper to convert a node to an element.
pub inline fn nodeToElement(node: *Node) *Element {
    return @as(*Element, @ptrCast(node));
}

// CharacterData
pub const CharacterData = c.dom_characterdata;

fn characterDataVtable(data: *CharacterData) c.dom_characterdata_vtable {
    return getVtable(c.dom_characterdata_vtable, CharacterData, data);
}

pub inline fn characterDataToNode(cdata: *CharacterData) *Node {
    return @as(*Node, @ptrCast(cdata));
}

pub fn characterDataData(cdata: *CharacterData) ![]const u8 {
    var s: ?*String = undefined;
    const err = characterDataVtable(cdata).dom_characterdata_get_data.?(cdata, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn characterDataSetData(cdata: *CharacterData, data: []const u8) !void {
    const s = try strFromData(data);
    const err = characterDataVtable(cdata).dom_characterdata_set_data.?(cdata, s);
    try DOMErr(err);
}

pub fn characterDataLength(cdata: *CharacterData) !u32 {
    var n: u32 = undefined;
    const err = characterDataVtable(cdata).dom_characterdata_get_length.?(cdata, &n);
    try DOMErr(err);
    return n;
}

pub fn characterDataAppendData(cdata: *CharacterData, data: []const u8) !void {
    const s = try strFromData(data);
    const err = characterDataVtable(cdata).dom_characterdata_append_data.?(cdata, s);
    try DOMErr(err);
}

pub fn characterDataDeleteData(cdata: *CharacterData, offset: u32, count: u32) !void {
    const err = characterDataVtable(cdata).dom_characterdata_delete_data.?(cdata, offset, count);
    try DOMErr(err);
}

pub fn characterDataInsertData(cdata: *CharacterData, offset: u32, data: []const u8) !void {
    const s = try strFromData(data);
    const err = characterDataVtable(cdata).dom_characterdata_insert_data.?(cdata, offset, s);
    try DOMErr(err);
}

pub fn characterDataReplaceData(cdata: *CharacterData, offset: u32, count: u32, data: []const u8) !void {
    const s = try strFromData(data);
    const err = characterDataVtable(cdata).dom_characterdata_replace_data.?(cdata, offset, count, s);
    try DOMErr(err);
}

pub fn characterDataSubstringData(cdata: *CharacterData, offset: u32, count: u32) ![]const u8 {
    var s: ?*String = undefined;
    const err = characterDataVtable(cdata).dom_characterdata_substring_data.?(cdata, offset, count, &s);
    try DOMErr(err);
    return strToData(s.?);
}

// CDATASection
pub const CDATASection = c.dom_cdata_section;

// Text
pub const Text = c.dom_text;

fn textVtable(text: *Text) c.dom_text_vtable {
    return getVtable(c.dom_text_vtable, Text, text);
}

pub fn textWholdeText(text: *Text) ![]const u8 {
    var s: ?*String = undefined;
    const err = textVtable(text).dom_text_get_whole_text.?(text, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn textSplitText(text: *Text, offset: u32) !*Text {
    var res: ?*Text = undefined;
    const err = textVtable(text).dom_text_split_text.?(text, offset, &res);
    try DOMErr(err);
    return res.?;
}

// Comment
pub const Comment = c.dom_comment;

// Attribute
pub const Attribute = c.dom_attr;

// Element
pub const Element = c.dom_element;

fn elementVtable(elem: *Element) c.dom_element_vtable {
    return getVtable(c.dom_element_vtable, Element, elem);
}

pub fn elementLocalName(elem: *Element) ![]const u8 {
    const node = @as(*Node, @ptrCast(elem));
    return try nodeLocalName(node);
}

pub fn elementGetAttribute(elem: *Element, name: []const u8) !?[]const u8 {
    var s: ?*String = undefined;
    const err = elementVtable(elem).dom_element_get_attribute.?(elem, try strFromData(name), &s);
    try DOMErr(err);
    if (s == null) return null;

    return strToData(s.?);
}

pub fn elementSetAttribute(elem: *Element, qname: []const u8, value: []const u8) !void {
    const err = elementVtable(elem).dom_element_set_attribute.?(
        elem,
        try strFromData(qname),
        try strFromData(value),
    );
    try DOMErr(err);
}

pub fn elementRemoveAttribute(elem: *Element, qname: []const u8) !void {
    const err = elementVtable(elem).dom_element_remove_attribute.?(elem, try strFromData(qname));
    try DOMErr(err);
}

pub fn elementHasAttribute(elem: *Element, qname: []const u8) !bool {
    var res: bool = undefined;
    const err = elementVtable(elem).dom_element_has_attribute.?(elem, try strFromData(qname), &res);
    try DOMErr(err);
    return res;
}

pub fn elementHasClass(elem: *Element, class: []const u8) !bool {
    var res: bool = undefined;
    const err = elementVtable(elem).dom_element_has_class.?(
        elem,
        try lwcStringFromData(class),
        &res,
    );
    try DOMErr(err);
    return res;
}

// elementToNode is an helper to convert an element to a node.
pub inline fn elementToNode(e: *Element) *Node {
    return @as(*Node, @ptrCast(e));
}

// ElementHTML
pub const ElementHTML = c.dom_html_element;

fn elementHTMLVtable(elem_html: *ElementHTML) c.dom_html_element_vtable {
    return getVtable(c.dom_html_element_vtable, ElementHTML, elem_html);
}

pub fn elementHTMLGetTagType(elem_html: *ElementHTML) !Tag {
    var tag_type: c.dom_html_element_type = undefined;
    const err = elementHTMLVtable(elem_html).dom_html_element_get_tag_type.?(elem_html, &tag_type);
    try DOMErr(err);
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

// Document Fragment
pub const DocumentFragment = c.dom_document_fragment;

// Document Position

pub const DocumentPosition = enum(u2) {
    disconnected = c.DOM_DOCUMENT_POSITION_DISCONNECTED,
    preceding = c.DOM_DOCUMENT_POSITION_PRECEDING,
    following = c.DOM_DOCUMENT_POSITION_FOLLOWING,
    contains = c.DOM_DOCUMENT_POSITION_CONTAINS,
    contained_by = c.DOM_DOCUMENT_POSITION_CONTAINED_BY,
    implementation_specific = c.DOM_DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC,
};

// DocumentType
pub const DocumentType = c.dom_document_type;

fn documentTypeVtable(dt: *DocumentType) c.dom_document_type_vtable {
    return getVtable(c.dom_document_type_vtable, DocumentType, dt);
}

pub inline fn documentTypeGetName(dt: *DocumentType) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentTypeVtable(dt).dom_document_type_get_name.?(dt, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentTypeGetPublicId(dt: *DocumentType) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentTypeVtable(dt).dom_document_type_get_public_id.?(dt, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentTypeGetSystemId(dt: *DocumentType) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentTypeVtable(dt).dom_document_type_get_system_id.?(dt, &s);
    try DOMErr(err);
    return strToData(s.?);
}

// DOMImplementation
pub inline fn domImplementationCreateDocument(
    namespace: ?[:0]const u8,
    qname: ?[:0]const u8,
    doctype: ?*DocumentType,
) !*Document {
    var doc: ?*Document = undefined;

    var ptrnamespace: [*c]const u8 = null;
    if (namespace) |ns| {
        ptrnamespace = ns.ptr;
    }

    var ptrqname: [*c]const u8 = null;
    if (qname) |qn| {
        ptrqname = qn.ptr;
    }

    const err = c.dom_implementation_create_document(
        c.DOM_IMPLEMENTATION_XML,
        ptrnamespace,
        ptrqname,
        doctype,
        null,
        null,
        &doc,
    );
    try DOMErr(err);
    return doc.?;
}

pub inline fn domImplementationCreateDocumentType(
    qname: [:0]const u8,
    publicId: [:0]const u8,
    systemId: [:0]const u8,
) !*DocumentType {
    var dt: ?*DocumentType = undefined;
    const err = c.dom_implementation_create_document_type(qname.ptr, publicId.ptr, systemId.ptr, &dt);
    try DOMErr(err);
    return dt.?;
}

pub inline fn domImplementationCreateHTMLDocument(title: ?[]const u8) !*Document {
    var doc: ?*Document = undefined;
    const err = c.dom_implementation_create_document(
        c.DOM_IMPLEMENTATION_HTML,
        null,
        null,
        null,
        null,
        null,
        &doc,
    );
    try DOMErr(err);
    // TODO set title
    _ = title;
    return doc.?;
}

// Document
pub const Document = c.dom_document;

fn documentVtable(doc: *Document) c.dom_document_vtable {
    return getVtable(c.dom_document_vtable, Document, doc);
}

pub inline fn documentGetElementById(doc: *Document, id: []const u8) !?*Element {
    var elem: ?*Element = undefined;
    const err = documentVtable(doc).dom_document_get_element_by_id.?(doc, try strFromData(id), &elem);
    try DOMErr(err);
    return elem;
}

pub inline fn documentGetElementsByTagName(doc: *Document, tagname: []const u8) !*NodeList {
    var nlist: ?*NodeList = undefined;
    const err = documentVtable(doc).dom_document_get_elements_by_tag_name.?(doc, try strFromData(tagname), &nlist);
    try DOMErr(err);
    return nlist.?;
}

// documentGetDocumentElement returns the root document element.
pub inline fn documentGetDocumentElement(doc: *Document) !*Element {
    var elem: ?*Element = undefined;
    const err = documentVtable(doc).dom_document_get_document_element.?(doc, &elem);
    try DOMErr(err);
    return elem.?;
}

pub inline fn documentGetDocumentURI(doc: *Document) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentVtable(doc).dom_document_get_uri.?(doc, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentGetInputEncoding(doc: *Document) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentVtable(doc).dom_document_get_input_encoding.?(doc, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentCreateElement(doc: *Document, tag_name: []const u8) !*Element {
    var elem: ?*Element = undefined;
    const err = documentVtable(doc).dom_document_create_element.?(doc, try strFromData(tag_name), &elem);
    try DOMErr(err);
    return elem.?;
}

pub inline fn documentCreateElementNS(doc: *Document, ns: []const u8, tag_name: []const u8) !*Element {
    var elem: ?*Element = undefined;
    const err = documentVtable(doc).dom_document_create_element_ns.?(
        doc,
        try strFromData(ns),
        try strFromData(tag_name),
        &elem,
    );
    try DOMErr(err);
    return elem.?;
}

pub inline fn documentGetDoctype(doc: *Document) !?*DocumentType {
    var dt: ?*DocumentType = undefined;
    const err = documentVtable(doc).dom_document_get_doctype.?(doc, &dt);
    try DOMErr(err);
    return dt;
}

pub inline fn documentCreateDocumentFragment(doc: *Document) !*DocumentFragment {
    var df: ?*DocumentFragment = undefined;
    const err = documentVtable(doc).dom_document_create_document_fragment.?(doc, &df);
    try DOMErr(err);
    return df.?;
}

pub inline fn documentCreateTextNode(doc: *Document, s: []const u8) !*Text {
    var txt: ?*Text = undefined;
    const err = documentVtable(doc).dom_document_create_text_node.?(doc, try strFromData(s), &txt);
    try DOMErr(err);
    return txt.?;
}

pub inline fn documentCreateCDATASection(doc: *Document, s: []const u8) !*CDATASection {
    var cdata: ?*CDATASection = undefined;
    const err = documentVtable(doc).dom_document_create_cdata_section.?(doc, try strFromData(s), &cdata);
    try DOMErr(err);
    return cdata.?;
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
    if (doc == null) return error.ParserError;
    return @as(*DocumentHTML, @ptrCast(doc.?));
}

// documentHTMLParseFromStrAlloc the given string.
// The allocator is required to create a null terminated string.
// The c string allocated is freed by the function.
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromStrAlloc(allocator: std.mem.Allocator, str: []const u8) !*DocumentHTML {
    // create a null terminated c string.
    const cstr = try allocator.dupeZ(u8, str);
    defer allocator.free(cstr);
    return documentHTMLParseFromStr(cstr);
}

// documentHTMLParseFromStr parses the given c string (ie. with 0 sentinel).
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromStr(cstr: [:0]const u8) !*DocumentHTML {
    const doc = c.wr_create_doc_dom_from_string(cstr.ptr);
    if (doc == null) return error.ParserError;
    return @as(*DocumentHTML, @ptrCast(doc.?));
}

// documentHTMLClose closes the document.
pub fn documentHTMLClose(doc: *DocumentHTML) !void {
    const err = documentHTMLVtable(doc).close.?(doc);
    try DOMErr(err);
}

pub inline fn documentHTMLToDocument(doc_html: *DocumentHTML) *Document {
    return @as(*Document, @ptrCast(doc_html));
}

pub inline fn documentHTMLBody(doc_html: *DocumentHTML) !?*Body {
    var body: ?*ElementHTML = undefined;
    const err = documentHTMLVtable(doc_html).get_body.?(doc_html, &body);
    try DOMErr(err);
    if (body == null) return null;
    return @as(*Body, @ptrCast(body.?));
}
