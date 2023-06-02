const std = @import("std");

const c = @cImport({
    @cInclude("lexbor/html/html.h");
});

// Public API
// ----------

// Tag

pub const Tag = enum(u8) {
    a = c.LXB_TAG_A,
    area = c.LXB_TAG_AREA,
    audio = c.LXB_TAG_AUDIO,
    br = c.LXB_TAG_BR,
    base = c.LXB_TAG_BASE,
    body = c.LXB_TAG_BODY,
    button = c.LXB_TAG_BUTTON,
    canvas = c.LXB_TAG_CANVAS,
    dl = c.LXB_TAG_DL,
    dialog = c.LXB_TAG_DIALOG,
    data = c.LXB_TAG_DATA,
    div = c.LXB_TAG_DIV,
    embed = c.LXB_TAG_EMBED,
    fieldset = c.LXB_TAG_FIELDSET,
    form = c.LXB_TAG_FORM,
    frameset = c.LXB_TAG_FRAMESET,
    hr = c.LXB_TAG_HR,
    head = c.LXB_TAG_HEAD,
    h1 = c.LXB_TAG_H1,
    h2 = c.LXB_TAG_H2,
    h3 = c.LXB_TAG_H3,
    h4 = c.LXB_TAG_H4,
    h5 = c.LXB_TAG_H5,
    h6 = c.LXB_TAG_H6,
    html = c.LXB_TAG_HTML,
    iframe = c.LXB_TAG_IFRAME,
    img = c.LXB_TAG_IMG,
    input = c.LXB_TAG_INPUT,
    li = c.LXB_TAG_LI,
    label = c.LXB_TAG_LABEL,
    legend = c.LXB_TAG_LEGEND,
    link = c.LXB_TAG_LINK,
    map = c.LXB_TAG_MAP,
    meta = c.LXB_TAG_META,
    meter = c.LXB_TAG_METER,
    ins = c.LXB_TAG_INS,
    del = c.LXB_TAG_DEL,
    ol = c.LXB_TAG_OL,
    object = c.LXB_TAG_OBJECT,
    optgroup = c.LXB_TAG_OPTGROUP,
    option = c.LXB_TAG_OPTION,
    output = c.LXB_TAG_OUTPUT,
    p = c.LXB_TAG_P,
    picture = c.LXB_TAG_PICTURE,
    pre = c.LXB_TAG_PRE,
    progress = c.LXB_TAG_PROGRESS,
    blockquote = c.LXB_TAG_BLOCKQUOTE,
    q = c.LXB_TAG_Q,
    script = c.LXB_TAG_SCRIPT,
    select = c.LXB_TAG_SELECT,
    source = c.LXB_TAG_SOURCE,
    span = c.LXB_TAG_SPAN,
    style = c.LXB_TAG_STYLE,
    table = c.LXB_TAG_TABLE,
    caption = c.LXB_TAG_CAPTION,
    th = c.LXB_TAG_TH,
    td = c.LXB_TAG_TD,
    col = c.LXB_TAG_COL,
    tr = c.LXB_TAG_TR,
    thead = c.LXB_TAG_THEAD,
    tbody = c.LXB_TAG_TBODY,
    tfoot = c.LXB_TAG_TFOOT,
    template = c.LXB_TAG_TEMPLATE,
    textarea = c.LXB_TAG_TEXTAREA,
    time = c.LXB_TAG_TIME,
    title = c.LXB_TAG_TITLE,
    track = c.LXB_TAG_TRACK,
    ul = c.LXB_TAG_UL,
    video = c.LXB_TAG_VIDEO,
    undef = c.LXB_TAG__UNDEF,

    pub fn all() []Tag {
        comptime {
            const info = @typeInfo(Tag).Enum;
            comptime var l: [info.fields.len]Tag = undefined;
            inline for (info.fields) |field, i| {
                l[i] = @intToEnum(Tag, field.value);
            }
            return &l;
        }
    }

    pub fn allElements() [][]const u8 {
        comptime {
            const tags = all();
            var names: [tags.len][]const u8 = undefined;
            inline for (tags) |tag, i| {
                names[i] = tag.elementName();
            }
            return &names;
        }
    }

    fn upperName(comptime name: []const u8) []const u8 {
        comptime {
            var upper_name: [name.len]u8 = undefined;
            for (name) |char, i| {
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

pub inline fn nodeEventTarget(node: *Node) *EventTarget {
    return c.lxb_dom_interface_event_target(node);
}

pub inline fn nodeTag(node: *Node) Tag {
    return @intToEnum(Tag, c.lxb_dom_node_tag_id(node));
}

pub const nodeWalker = (fn (node: ?*Node, _: ?*anyopaque) callconv(.C) Action);

pub inline fn nodeName(node: *Node) [*c]const u8 {
    var s: usize = undefined;
    return c.lxb_dom_node_name(node, &s);
}

pub inline fn nodeType(node: *Node) NodeType {
    return @intToEnum(NodeType, node.*.type);
}

pub inline fn nodeWalk(node: *Node, comptime walker: nodeWalker) !void {
    c.lxb_dom_node_simple_walk(node, walker, null);
}

// Element

pub const Element = c.lxb_dom_element_t;

pub inline fn elementNode(element: *Element) *Node {
    return c.lxb_dom_interface_node(element);
}

pub inline fn elementLocalName(element: *Element) []const u8 {
    var size: usize = undefined;
    const local_name = c.lxb_dom_element_local_name(element, &size);
    return std.mem.sliceTo(local_name, 0);
}

pub inline fn elementsByAttr(
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

pub inline fn documentHTMLInit() *DocumentHTML {
    return c.lxb_html_document_create();
}

pub inline fn documentHTMLDeinit(document_html: *DocumentHTML) void {
    _ = c.lxb_html_document_destroy(document_html);
}

pub inline fn documentHTMLParse(document_html: *DocumentHTML, html: []const u8) !void {
    const status = c.lxb_html_document_parse(document_html, html.ptr, html.len - 1);
    if (status != 0) {
        return error.DocumentHTMLParse;
    }
}

pub inline fn documentHTMLToNode(document_html: *DocumentHTML) *Node {
    return c.lxb_dom_interface_node(document_html);
}

pub inline fn documentHTMLToDocument(document_html: *DocumentHTML) *Document {
    return &document_html.dom_document;
}

pub inline fn documentHTMLBody(document_html: *DocumentHTML) *Body {
    return document_html.body;
}

// Document

pub const Document = c.lxb_dom_document_t;

pub inline fn documentCreateElement(document: *Document, tag_name: []const u8) *Element {
    return c.lxb_dom_document_create_element(document, tag_name.ptr, tag_name.len, null);
}

// Collection

pub const Collection = c.lxb_dom_collection_t;

pub inline fn collectionInit(document: *Document, size: usize) *Collection {
    return c.lxb_dom_collection_make(document, size);
}

pub inline fn collectionDeinit(collection: *Collection) void {
    _ = c.lxb_dom_collection_destroy(collection, true);
}

pub inline fn collectionElement(collection: *Collection, index: usize) *Element {
    return c.lxb_dom_collection_element(collection, index);
}

// HTML Elements

pub const HTMLElement = c.lxb_html_element_t;
pub const MediaElement = c.lxb_html_media_element_t;

pub const Unknown = c.lxb_html_unknown_element_t;
pub const Anchor = c.lxb_html_anchor_element_t;
pub const Area = c.lxb_html_area_element_t;
pub const Audio = c.lxb_html_audio_element_t;
pub const BR = c.lxb_html_br_element_t;
pub const Base = c.lxb_html_base_element_t;
pub const Body = c.lxb_html_body_element_t;
pub const Button = c.lxb_html_button_element_t;
pub const Canvas = c.lxb_html_canvas_element_t;
pub const DList = c.lxb_html_d_list_element_t;
pub const Data = c.lxb_html_data_element_t;
pub const Dialog = c.lxb_html_dialog_element_t;
pub const Div = c.lxb_html_div_element_t;
pub const Embed = c.lxb_html_embed_element_t;
pub const FieldSet = c.lxb_html_field_set_element_t;
pub const Form = c.lxb_html_form_element_t;
pub const FrameSet = c.lxb_html_frame_set_element_t;
pub const HR = c.lxb_html_hr_element_t;
pub const Head = c.lxb_html_head_element_t;
pub const Heading = c.lxb_html_heading_element_t;
pub const Html = c.lxb_html_html_element_t;
pub const IFrame = c.lxb_html_iframe_element_t;
pub const Image = c.lxb_html_image_element_t;
pub const Input = c.lxb_html_input_element_t;
pub const LI = c.lxb_html_li_element_t;
pub const Label = c.lxb_html_label_element_t;
pub const Legend = c.lxb_html_legend_element_t;
pub const Link = c.lxb_html_link_element_t;
pub const Map = c.lxb_html_map_element_t;
pub const Meta = c.lxb_html_meta_element_t;
pub const Meter = c.lxb_html_meter_element_t;
pub const Mod = c.lxb_html_mod_element_t;
pub const OList = c.lxb_html_o_list_element_t;
pub const Object = c.lxb_html_object_element_t;
pub const OptGroup = c.lxb_html_opt_group_element_t;
pub const Option = c.lxb_html_option_element_t;
pub const Output = c.lxb_html_output_element_t;
pub const Paragraph = c.lxb_html_paragraph_element_t;
pub const Picture = c.lxb_html_picture_element_t;
pub const Pre = c.lxb_html_pre_element_t;
pub const Progress = c.lxb_html_progress_element_t;
pub const Quote = c.lxb_html_quote_element_t;
pub const Script = c.lxb_html_script_element_t;
pub const Select = c.lxb_html_select_element_t;
pub const Source = c.lxb_html_source_element_t;
pub const Span = c.lxb_html_span_element_t;
pub const Style = c.lxb_html_style_element_t;
pub const Table = c.lxb_html_table_element_t;
pub const TableCaption = c.lxb_html_table_caption_element_t;
pub const TableCell = c.lxb_html_table_cell_element_t;
pub const TableCol = c.lxb_html_table_col_element_t;
pub const TableRow = c.lxb_html_table_row_element_t;
pub const TableSection = c.lxb_html_table_section_element_t;
pub const Template = c.lxb_html_template_element_t;
pub const TextArea = c.lxb_html_text_area_element_t;
pub const Time = c.lxb_html_time_element_t;
pub const Title = c.lxb_html_title_element_t;
pub const Track = c.lxb_html_track_element_t;
pub const UList = c.lxb_html_u_list_element_t;
pub const Video = c.lxb_html_video_element_t;

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
