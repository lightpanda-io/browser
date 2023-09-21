const std = @import("std");

const cp = @cImport({
    @cInclude("wrapper.h");
});

const c = @cImport({
    @cInclude("core/node.h");
    @cInclude("core/document.h");
    @cInclude("core/element.h");

    @cInclude("html/html_document.h");
    @cInclude("html/html_element.h");
    @cInclude("html/html_anchor_element.h");
    @cInclude("html/html_area_element.h");
    @cInclude("html/html_br_element.h");
    @cInclude("html/html_base_element.h");
    @cInclude("html/html_body_element.h");
    @cInclude("html/html_button_element.h");
    @cInclude("html/html_canvas_element.h");
    @cInclude("html/html_dlist_element.h");
    @cInclude("html/html_div_element.h");
    @cInclude("html/html_fieldset_element.h");
    @cInclude("html/html_form_element.h");
    @cInclude("html/html_frameset_element.h");
    @cInclude("html/html_hr_element.h");
    @cInclude("html/html_head_element.h");
    @cInclude("html/html_heading_element.h");
    @cInclude("html/html_html_element.h");
    @cInclude("html/html_iframe_element.h");
    @cInclude("html/html_image_element.h");
    @cInclude("html/html_input_element.h");
    @cInclude("html/html_li_element.h");
    @cInclude("html/html_label_element.h");
    @cInclude("html/html_legend_element.h");
    @cInclude("html/html_link_element.h");
    @cInclude("html/html_map_element.h");
    @cInclude("html/html_meta_element.h");
    @cInclude("html/html_mod_element.h");
    @cInclude("html/html_olist_element.h");
    @cInclude("html/html_object_element.h");
    @cInclude("html/html_opt_group_element.h");
    @cInclude("html/html_option_element.h");
    @cInclude("html/html_paragraph_element.h");
    @cInclude("html/html_pre_element.h");
    @cInclude("html/html_quote_element.h");
    @cInclude("html/html_script_element.h");
    @cInclude("html/html_select_element.h");
    @cInclude("html/html_style_element.h");
    @cInclude("html/html_table_element.h");
    @cInclude("html/html_tablecaption_element.h");
    @cInclude("html/html_tablecell_element.h");
    @cInclude("html/html_tablecol_element.h");
    @cInclude("html/html_tablerow_element.h");
    @cInclude("html/html_tablesection_element.h");
    @cInclude("html/html_text_area_element.h");
    @cInclude("html/html_title_element.h");
    @cInclude("html/html_ulist_element.h");
});

// Utils
const String = c.dom_string;

inline fn stringToData(s: *String) []const u8 {
    const data = c.dom_string_data(s);
    return data[0..c.dom_string_byte_length(s)];
}

inline fn stringFromData(data: []const u8) *String {
    var s: ?*String = null;
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

// Node
pub const Node = c.dom_node_internal;

// Element
pub const Element = c.dom_element;

pub fn elementLocalName(elem: *Element) []const u8 {
    const elem_aligned: *align(8) Element = @alignCast(elem);
    const node = @as(*Node, @ptrCast(elem_aligned));
    var s: ?*String = null;
    _ = c._dom_node_get_local_name(node, &s);
    var s_lower: ?*String = null;
    _ = c.dom_string_tolower(s, true, &s_lower);
    return stringToData(s_lower.?);
}

// ElementHTML
pub const ElementHTML = c.dom_html_element;

pub fn elementHTMLGetTagType(elem_html: *ElementHTML) Tag {
    var tag_type: c.dom_html_element_type = undefined;
    _ = c._dom_html_element_get_tag_type(elem_html, &tag_type);
    return @as(Tag, @enumFromInt(tag_type));
}

// ElementsHTML

pub const MediaElement = struct { base: c.dom_html_element };

pub const Unknown = struct { base: c.dom_html_element };
pub const Anchor = c.dom_html_anchor_element;
pub const Area = c.dom_html_area_element;
pub const Audio = struct { base: c.dom_html_element };
pub const BR = c.dom_html_br_element;
pub const Base = c.dom_html_base_element;
pub const Body = c.dom_html_body_element;
pub const Button = c.dom_html_button_element;
pub const Canvas = c.dom_html_canvas_element;
pub const DList = c.dom_html_dlist_element;
pub const Data = struct { base: c.dom_html_element };
pub const Dialog = struct { base: c.dom_html_element };
pub const Div = c.dom_html_div_element;
pub const Embed = struct { base: c.dom_html_element };
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
pub const Meter = struct { base: c.dom_html_element };
pub const Mod = c.dom_html_mod_element;
pub const OList = c.dom_html_olist_element;
pub const Object = c.dom_html_object_element;
pub const OptGroup = c.dom_html_opt_group_element;
pub const Option = c.dom_html_option_element;
pub const Output = struct { base: c.dom_html_element };
pub const Paragraph = c.dom_html_paragraph_element;
pub const Picture = struct { base: c.dom_html_element };
pub const Pre = c.dom_html_pre_element;
pub const Progress = struct { base: c.dom_html_element };
pub const Quote = c.dom_html_quote_element;
pub const Script = c.dom_html_script_element;
pub const Select = c.dom_html_select_element;
pub const Source = struct { base: c.dom_html_element };
pub const Span = struct { base: c.dom_html_element };
pub const Style = c.dom_html_style_element;
pub const Table = c.dom_html_table_element;
pub const TableCaption = c.dom_html_table_caption_element;
pub const TableCell = c.dom_html_table_cell_element;
pub const TableCol = c.dom_html_table_col_element;
pub const TableRow = c.dom_html_table_row_element;
pub const TableSection = c.dom_html_table_section_element;
pub const Template = struct { base: c.dom_html_element };
pub const TextArea = c.dom_html_text_area_element;
pub const Time = struct { base: c.dom_html_element };
pub const Title = c.dom_html_title_element;
pub const Track = struct { base: c.dom_html_element };
pub const UList = c.dom_html_u_list_element;
pub const Video = struct { base: c.dom_html_element };

// Document
pub const Document = c.dom_document;

pub inline fn documentGetElementById(doc: *Document, id: []const u8) ?*Element {
    var elem: ?*Element = null;
    _ = c._dom_document_get_element_by_id(doc, stringFromData(id), &elem);
    return elem;
}

pub inline fn documentCreateElement(doc: *Document, tag_name: []const u8) *Element {
    var elem: ?*Element = null;
    _ = c._dom_html_document_create_element(doc, stringFromData(tag_name), &elem);
    return elem.?;
}

// DocumentHTML
pub const DocumentHTML = c.dom_html_document;

pub fn documentHTMLParse(filename: []u8) *DocumentHTML {
    const doc = cp.wr_create_doc_dom_from_file(filename.ptr);
    if (doc == null) {
        @panic("error parser");
    }
    const doc_aligned: *align(@alignOf((DocumentHTML))) cp.dom_document = @alignCast(doc.?);
    return @as(*DocumentHTML, @ptrCast(doc_aligned));
}

pub inline fn documentHTMLToDocument(doc_html: *DocumentHTML) *Document {
    return @as(*Document, @ptrCast(doc_html));
}

pub inline fn documentHTMLBody(doc_html: *DocumentHTML) ?*Body {
    var body: ?*ElementHTML = null;
    _ = c._dom_html_document_get_body(doc_html, &body);
    if (body) |value| {
        return @as(*Body, @ptrCast(value));
    }
    return null;
}

// TODO: Old

pub fn create_dom(filename: []u8) !void {
    const doc = c.wr_create_doc_dom_from_file(filename.ptr);
    if (doc == null) {
        @panic("error parser");
    }
    std.debug.print("doc: {any}\n", .{doc});
    const doc_html = @as(*DocumentHTML, @ptrCast(doc.?));

    var root: ?*Element = null;
    var exc = c.dom_document_get_document_element(doc, &root);
    if (exc != c.DOM_NO_ERR) {
        @panic("Exception raised for get_html_document_element");
    }
    if (root == null) {
        @panic("error root");
    }
    std.debug.print("root: {any}\n", .{root});

    const body = documentHTMLBody(doc_html);
    std.debug.print("body: {any}\n", .{body});
}
