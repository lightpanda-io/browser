// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const c = @cImport({
    @cInclude("dom/dom.h");
    @cInclude("core/pi.h");
    @cInclude("dom/bindings/hubbub/parser.h");
    @cInclude("events/event_target.h");
    @cInclude("events/event.h");
    @cInclude("events/mouse_event.h");
    @cInclude("events/keyboard_event.h");
    @cInclude("utils/validate.h");
    @cInclude("html/html_element.h");
    @cInclude("html/html_document.h");
});

const mimalloc = @import("mimalloc.zig");

// init initializes netsurf lib.
// init starts a mimalloc heap arena for the netsurf session. The caller must
// call deinit() to free the arena memory.
pub fn init() !void {
    try mimalloc.create();
}

// deinit frees the mimalloc heap arena memory.
// It also clean dom namespaces and lwc strings.
pub fn deinit() void {
    _ = c.dom_namespace_finalise();

    // destroy all lwc strings.
    c.lwc_deinit_strings();

    mimalloc.destroy();
}

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

pub inline fn strFromData(data: []const u8) !*String {
    var s: ?*String = null;
    const err = c.dom_string_create(data.ptr, data.len, &s);
    try DOMErr(err);
    return s.?;
}

const LWCString = c.lwc_string;

// TODO implement lwcStringToData
// inline fn lwcStringToData(s: *LWCString) []const u8 {
// }

inline fn lwcStringFromData(data: []const u8) !*LWCString {
    var s: ?*LWCString = null;
    const err = c.lwc_intern_string(data.ptr, data.len, &s);
    try DOMErr(err);
    return s.?;
}

// Tag

pub const Tag = enum(u8) {
    acronym = c.DOM_HTML_ELEMENT_TYPE_ACRONYM,
    applet = c.DOM_HTML_ELEMENT_TYPE_APPLET,
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
    base = c.DOM_HTML_ELEMENT_TYPE_BASE,
    basefont = c.DOM_HTML_ELEMENT_TYPE_BASEFONT,
    bdi = c.DOM_HTML_ELEMENT_TYPE_BDI,
    bdo = c.DOM_HTML_ELEMENT_TYPE_BDO,
    br = c.DOM_HTML_ELEMENT_TYPE_BR,
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
    em = c.DOM_HTML_ELEMENT_TYPE_EM,
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
    keygen = c.DOM_HTML_ELEMENT_TYPE_KEYGEN,
    li = c.DOM_HTML_ELEMENT_TYPE_LI,
    label = c.DOM_HTML_ELEMENT_TYPE_LABEL,
    legend = c.DOM_HTML_ELEMENT_TYPE_LEGEND,
    link = c.DOM_HTML_ELEMENT_TYPE_LINK,
    main = c.DOM_HTML_ELEMENT_TYPE_MAIN,
    map = c.DOM_HTML_ELEMENT_TYPE_MAP,
    mark = c.DOM_HTML_ELEMENT_TYPE_MARK,
    menu = c.DOM_HTML_ELEMENT_TYPE_MENU,
    menuitem = c.DOM_HTML_ELEMENT_TYPE_MENUITEM,
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
    strong = c.DOM_HTML_ELEMENT_TYPE_STRONG,
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
    slot = c.DOM_HTML_ELEMENT_TYPE_SLOT,
    undef = c.DOM_HTML_ELEMENT_TYPE__UNKNOWN,

    pub fn all() []Tag {
        comptime {
            const info = @typeInfo(Tag).@"enum";
            var l: [info.fields.len]Tag = undefined;
            for (info.fields, 0..) |field, i| {
                l[i] = @as(Tag, @enumFromInt(field.value));
            }
            return &l;
        }
    }

    pub fn allElements() [][]const u8 {
        comptime {
            const tags = all();
            var names: [tags.len][]const u8 = undefined;
            for (tags, 0..) |tag, i| {
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

    pub fn fromString(tagname: []const u8) !Tag {
        inline for (@typeInfo(Tag).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, tagname)) {
                return @enumFromInt(field.value);
            }
        }

        return error.Invalid;
    }

    const testing = @import("../testing.zig");
    test "Tag.fromString" {
        try testing.expect(try Tag.fromString("ABBR") == .abbr);
        try testing.expect(try Tag.fromString("abbr") == .abbr);

        try testing.expect(Tag.fromString("foo") == error.Invalid);
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

    // custom netsurf error
    UnspecifiedEventType,
    DispatchRequest,
    NoMemory,
    AttributeWrongType,
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

        // custom netsurf error
        c.DOM_UNSPECIFIED_EVENT_TYPE_ERR => DOMError.UnspecifiedEventType,
        c.DOM_DISPATCH_REQUEST_ERR => DOMError.DispatchRequest,
        c.DOM_NO_MEM_ERR => DOMError.NoMemory,
        c.DOM_ATTR_WRONG_TYPE_ERR => DOMError.AttributeWrongType,

        else => unreachable,
    };
}

// Event
pub const Event = c.dom_event;

pub fn eventCreate() !*Event {
    var evt: ?*Event = null;
    const err = c._dom_event_create(&evt);
    try DOMErr(err);
    return evt.?;
}

pub const EventInit = struct {
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,
};

pub fn eventDestroy(evt: *Event) void {
    c._dom_event_destroy(evt);
}

pub fn eventInit(evt: *Event, typ: []const u8, opts: EventInit) !void {
    const s = try strFromData(typ);
    const err = c._dom_event_init(evt, s, opts.bubbles, opts.cancelable);
    try DOMErr(err);
}

pub fn eventType(evt: *Event) ![]const u8 {
    var s: ?*String = null;
    const err = c._dom_event_get_type(evt, &s);
    try DOMErr(err);

    // if the event type is null, return a empty string.
    if (s == null) return "";

    return strToData(s.?);
}

pub fn eventTarget(evt: *Event) ?*EventTarget {
    var et: ?*EventTarget = null;
    const err = c._dom_event_get_target(evt, &et);
    std.debug.assert(err == c.DOM_NO_ERR);
    return et;
}

pub fn eventCurrentTarget(evt: *Event) ?*EventTarget {
    var et: ?*EventTarget = null;
    const err = c._dom_event_get_current_target(evt, &et);
    std.debug.assert(err == c.DOM_NO_ERR);
    return et;
}

pub fn eventPhase(evt: *Event) u8 {
    var phase: c.dom_event_flow_phase = undefined;
    const err = c._dom_event_get_event_phase(evt, &phase);
    std.debug.assert(err == c.DOM_NO_ERR);
    return @as(u8, @intCast(phase));
}

pub fn eventBubbles(evt: *Event) bool {
    var res: bool = undefined;
    const err = c._dom_event_get_bubbles(evt, &res);
    std.debug.assert(err == c.DOM_NO_ERR);
    return res;
}

pub fn eventCancelable(evt: *Event) bool {
    var res: bool = undefined;
    const err = c._dom_event_get_cancelable(evt, &res);
    std.debug.assert(err == c.DOM_NO_ERR);
    return res;
}

pub fn eventDefaultPrevented(evt: *Event) bool {
    var res: bool = undefined;
    const err = c._dom_event_is_default_prevented(evt, &res);
    std.debug.assert(err == c.DOM_NO_ERR);
    return res;
}

pub fn eventIsTrusted(evt: *Event) bool {
    var res: bool = undefined;
    const err = c._dom_event_get_is_trusted(evt, &res);
    std.debug.assert(err == c.DOM_NO_ERR);
    return res;
}

pub fn eventTimestamp(evt: *Event) u64 {
    var ts: u64 = 0;
    const err = c._dom_event_get_timestamp(evt, &ts);
    std.debug.assert(err == c.DOM_NO_ERR);
    return ts;
}

pub fn eventStopPropagation(evt: *Event) void {
    const err = c._dom_event_stop_propagation(evt);
    std.debug.assert(err == c.DOM_NO_ERR);
}

pub fn eventIsStopped(evt: *Event) bool {
    var res: bool = undefined;
    const err = c._dom_event_is_stopped(evt, &res);
    std.debug.assert(err == c.DOM_NO_ERR);
    return res;
}

pub fn eventStopImmediatePropagation(evt: *Event) void {
    const err = c._dom_event_stop_immediate_propagation(evt);
    std.debug.assert(err == c.DOM_NO_ERR);
}

pub fn eventPreventDefault(evt: *Event) void {
    const err = c._dom_event_prevent_default(evt);
    std.debug.assert(err == c.DOM_NO_ERR);
}

pub fn eventGetInternalType(evt: *Event) EventType {
    var res: u32 = undefined;
    const err = c._dom_event_get_internal_type(evt, &res);
    std.debug.assert(err == c.DOM_NO_ERR);
    return @enumFromInt(res);
}

pub fn eventSetInternalType(evt: *Event, internal_type: EventType) void {
    const err = c._dom_event_set_internal_type(evt, @intFromEnum(internal_type));
    std.debug.assert(err == c.DOM_NO_ERR);
}

pub const EventType = enum(u8) {
    event = 0,
    progress_event = 1,
    custom_event = 2,
    mouse_event = 3,
    error_event = 4,
    abort_signal = 5,
    xhr_event = 6,
    message_event = 7,
    keyboard_event = 8,
};

pub const MutationEvent = c.dom_mutation_event;

pub fn eventToMutationEvent(evt: *Event) *MutationEvent {
    return @as(*MutationEvent, @ptrCast(evt));
}

pub fn mutationEventAttributeName(evt: *MutationEvent) ![]const u8 {
    var s: ?*String = null;
    const err = c._dom_mutation_event_get_attr_name(evt, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn mutationEventPrevValue(evt: *MutationEvent) !?[]const u8 {
    var s: ?*String = null;
    const err = c._dom_mutation_event_get_prev_value(evt, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn mutationEventNewValue(evt: *MutationEvent) !?[]const u8 {
    var s: ?*String = null;
    const err = c._dom_mutation_event_get_new_value(evt, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn mutationEventRelatedNode(evt: *MutationEvent) !?*Node {
    var n: NodeExternal = undefined;
    const err = c._dom_mutation_event_get_related_node(evt, &n);
    try DOMErr(err);
    if (n == null) return null;
    return @as(*Node, @ptrCast(@alignCast(n)));
}

// EventListener
pub const EventListener = c.dom_event_listener;
const EventListenerEntry = c.listener_entry;

fn eventListenerGetData(lst: *EventListener) ?*anyopaque {
    return c.dom_event_listener_get_data(lst);
}

// EventTarget
pub const EventTarget = c.dom_event_target;

pub fn eventTargetToNode(et: *EventTarget) *Node {
    return @as(*Node, @ptrCast(@alignCast(et)));
}

fn eventTargetVtable(et: *EventTarget) c.dom_event_target_vtable {
    // retrieve the vtable
    const vtable = et.*.vtable.?;
    // align correctly the vtable
    const vtable_aligned: *align(@alignOf([*c]c.dom_event_target_vtable)) const anyopaque = @alignCast(vtable);
    // convert the vtable to it's actual type and return it
    return @as([*c]const c.dom_event_target_vtable, @ptrCast(vtable_aligned)).*;
}

pub fn toEventTarget(comptime T: type, v: *T) *EventTarget {
    if (comptime eventTargetTBaseFieldName(T)) |field| {
        const et_aligned: *align(@alignOf(EventTarget)) EventTargetTBase = @alignCast(&@field(v, field));
        return @as(*EventTarget, @ptrCast(et_aligned));
    }

    const et_aligned: *align(@alignOf(EventTarget)) T = @alignCast(v);
    return @as(*EventTarget, @ptrCast(et_aligned));
}

// The way we implement events is a lot like how Zig implements linked lists.
// A Zig struct contains an `EventNode` field, i.e.:
//    node: parser.EventNode,
//
// When eventTargetAddEventListener is called, we pass in `&self.node`.
// This is the pointer that's stored in the netsurf listener and it's the data
// we can get back from the listener. We can call the node's `func` function,
// passing the node itself, and the receiving function will know how to turn
// that node into the our "self", i..e by using @fieldParentPtr.
// https://www.openmymind.net/Zigs-New-LinkedList-API/
pub const EventNode = struct {
    // Event id, used for removing. Internal Zig events won't have an id.
    // This is normally set to the callback.id for a JavaScript event.
    id: ?usize = null,

    func: *const fn (node: *EventNode, event: *Event) void,

    fn idFromListener(lst: *EventListener) ?usize {
        const ctx = eventListenerGetData(lst) orelse return null;
        const node: *EventNode = @ptrCast(@alignCast(ctx));
        return node.id;
    }
};

pub fn eventTargetAddEventListener(
    et: *EventTarget,
    typ: []const u8,
    node: *EventNode,
    capture: bool,
) !*EventListener {
    const event_handler = struct {
        fn handle(event_: ?*Event, ptr_: ?*anyopaque) callconv(.c) void {
            const ptr = ptr_ orelse return;
            const event = event_ orelse return;

            const node_: *EventNode = @ptrCast(@alignCast(ptr));
            node_.func(node_, event);
        }
    }.handle;

    var listener: ?*EventListener = null;
    const errLst = c.dom_event_listener_create(event_handler, node, &listener);
    try DOMErr(errLst);
    defer c.dom_event_listener_unref(listener);

    const s = try strFromData(typ);
    const err = eventTargetVtable(et).add_event_listener.?(et, s, listener, capture);
    try DOMErr(err);

    return listener.?;
}

pub fn eventTargetHasListener(
    et: *EventTarget,
    typ: []const u8,
    capture: bool,
    id: usize,
) !?*EventListener {
    const str = try strFromData(typ);

    var current: ?*EventListenerEntry = null;
    var next: ?*EventListenerEntry = null;
    var lst: ?*EventListener = null;

    // iterate over the EventTarget's listeners
    const iter_event_listener = eventTargetVtable(et).iter_event_listener.?;
    while (true) {
        const err = iter_event_listener(
            et,
            str,
            capture,
            current,
            &next,
            &lst,
        );
        try DOMErr(err);

        if (lst) |listener| {
            // the EventTarget has a listener for this event type
            // and capture property,
            // let's check if the callback handler is the same
            defer c.dom_event_listener_unref(listener);
            if (EventNode.idFromListener(listener)) |node_id| {
                if (node_id == id) {
                    return lst;
                }
            }
        }

        if (next == null) {
            // no more listeners, end of the iteration
            break;
        }

        // next iteration
        current = next;
    }

    return null;
}

pub fn eventTargetRemoveEventListener(
    et: *EventTarget,
    typ: []const u8,
    lst: *EventListener,
    capture: bool,
) !void {
    const s = try strFromData(typ);
    const err = eventTargetVtable(et).remove_event_listener.?(et, s, lst, capture);
    try DOMErr(err);
}

pub fn eventTargetRemoveAllEventListeners(et: *EventTarget) !void {
    var next: ?*EventListenerEntry = null;
    var lst: ?*EventListener = null;

    // iterate over the EventTarget's listeners
    const iter_event_listener = eventTargetVtable(et).iter_event_listener.?;
    while (true) {
        const errIter = iter_event_listener(
            et,
            null,
            false,
            null,
            &next,
            &lst,
        );
        try DOMErr(errIter);

        if (lst) |listener| {
            if (EventNode.idFromListener(listener) != null) {
                defer c.dom_event_listener_unref(listener);
                const err = eventTargetVtable(et).remove_event_listener.?(
                    et,
                    null,
                    lst,
                    false,
                );
                try DOMErr(err);
            }
        }

        if (next == null) {
            // no more listeners, end of the iteration
            break;
        }

        // next iteration
    }
}

pub fn eventTargetDispatchEvent(et: *EventTarget, event: *Event) !bool {
    var res: bool = undefined;
    const err = eventTargetVtable(et).dispatch_event.?(et, event, &res);
    try DOMErr(err);
    return res;
}

pub fn eventTargetInternalType(et: *EventTarget) !EventTargetTBase.InternalType {
    var res: u32 = undefined;
    const err = eventTargetVtable(et).internal_type.?(et, &res);
    try DOMErr(err);
    return @enumFromInt(res);
}

pub fn elementDispatchEvent(element: *Element, event: *Event) !bool {
    const et: *EventTarget = toEventTarget(Element, element);
    return eventTargetDispatchEvent(et, @ptrCast(event));
}

pub fn eventTargetTBaseFieldName(comptime T: type) ?[]const u8 {
    std.debug.assert(@inComptime());
    switch (@typeInfo(T)) {
        .@"struct" => |ti| {
            for (ti.fields) |f| {
                if (f.type == EventTargetTBase) return f.name;
            }
        },
        else => {},
    }

    return null;
}

// EventTargetBase is used to implement EventTarget for pure zig struct.
pub const EventTargetTBase = extern struct {
    const Self = @This();
    const InternalType = enum(u32) {
        libdom_node = 0,
        plain = 1,
        abort_signal = 2,
        xhr = 3,
        window = 4,
        performance = 5,
        media_query_list = 6,
        message_port = 7,
        screen = 8,
        screen_orientation = 9,
    };

    vtable: ?*const c.struct_dom_event_target_vtable = &c.struct_dom_event_target_vtable{
        .dispatch_event = dispatch_event,
        .remove_event_listener = remove_event_listener,
        .add_event_listener = add_event_listener,
        .iter_event_listener = iter_event_listener,
        .internal_type = internal_type,
    },

    // When we dispatch the event, we need to provide a target. In reality, the
    // target is the container of this EventTargetTBase. But we can't pass that
    // to _dom_event_target_dispatch, because it expects a dom_event_target.
    // If you try to pass an non-event_target, you'll get weird behavior. For
    // example, libdom might dom_node_ref that memory. Say we passed a *Window
    // as the target, what happens if libdom calls dom_node_ref(window)? If
    // you're lucky, you'll crash. If you're unlucky, you'll increment a random
    // part of the window structure.
    refcnt: u32 = 0,

    eti: c.dom_event_target_internal = c.dom_event_target_internal{ .listeners = null },
    internal_target_type: InternalType,

    pub fn add_event_listener(et: [*c]c.dom_event_target, t: [*c]c.dom_string, l: ?*c.struct_dom_event_listener, capture: bool) callconv(.c) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        return c._dom_event_target_add_event_listener(&self.eti, t, l, capture);
    }

    pub fn dispatch_event(et: [*c]c.dom_event_target, evt: ?*c.struct_dom_event, res: [*c]bool) callconv(.c) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        // Set the event target to the target dispatched.
        const e = c._dom_event_set_target(evt, et);
        if (e != c.DOM_NO_ERR) {
            return e;
        }
        return c._dom_event_target_dispatch(et, &self.eti, evt, c.DOM_AT_TARGET, res);
    }

    pub fn remove_event_listener(et: [*c]c.dom_event_target, t: [*c]c.dom_string, l: ?*c.struct_dom_event_listener, capture: bool) callconv(.c) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        return c._dom_event_target_remove_event_listener(&self.eti, t, l, capture);
    }

    pub fn iter_event_listener(
        et: [*c]c.dom_event_target,
        t: [*c]c.dom_string,
        capture: bool,
        cur: [*c]c.struct_listener_entry,
        next: [*c][*c]c.struct_listener_entry,
        l: [*c]?*c.struct_dom_event_listener,
    ) callconv(.c) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        return c._dom_event_target_iter_event_listener(self.eti, t, capture, cur, next, l);
    }

    pub fn internal_type(et: [*c]c.dom_event_target, internal_type_: [*c]u32) callconv(.c) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        internal_type_.* = @intFromEnum(self.internal_target_type);
        return c.DOM_NO_ERR;
    }

    // Called to simulate bubbling from a libdom node (e.g. the Document) to a
    // Zig instance (e.g. the Window).
    pub fn redispatchEvent(self: *EventTargetTBase, evt: *Event) !void {
        var res: bool = undefined;
        const err = c._dom_event_target_dispatch(@ptrCast(self), &self.eti, evt, c.DOM_BUBBLING_PHASE, &res);
        try DOMErr(err);
    }
};

// MouseEvent

pub const MouseEvent = c.dom_mouse_event;

pub fn mouseEventCreate() !*MouseEvent {
    var evt: ?*MouseEvent = null;
    const err = c._dom_mouse_event_create(&evt);
    try DOMErr(err);
    return evt.?;
}

pub fn mouseEventDestroy(evt: *MouseEvent) void {
    c._dom_mouse_event_destroy(evt);
}

const MouseEventOpts = struct {
    x: i32,
    y: i32,
    bubbles: bool = false,
    cancelable: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
    button: u16 = 0,
    click_count: u16 = 1,
};

pub fn mouseEventInit(evt: *MouseEvent, typ: []const u8, opts: MouseEventOpts) !void {
    const s = try strFromData(typ);
    const err = c._dom_mouse_event_init(
        evt,
        s,
        opts.bubbles,
        opts.cancelable,
        null, // dom_abstract_view* ?
        opts.click_count, // details
        opts.x, // screen_x
        opts.y, // screen_y
        opts.x, // client_x
        opts.y, // client_y
        opts.ctrl,
        opts.alt,
        opts.shift,
        opts.meta,
        opts.button,
        null, // related target
    );
    try DOMErr(err);
}

pub fn mouseEventDefaultPrevented(evt: *MouseEvent) !bool {
    return eventDefaultPrevented(@ptrCast(evt));
}

// KeyboardEvent

pub const KeyboardEvent = c.dom_keyboard_event;

pub fn keyboardEventCreate() !*KeyboardEvent {
    var evt: ?*KeyboardEvent = null;
    const err = c._dom_keyboard_event_create(&evt);
    try DOMErr(err);
    return evt.?;
}

pub fn keyboardEventDestroy(evt: *KeyboardEvent) void {
    c._dom_keyboard_event_destroy(evt);
}

pub fn keyboardEventKeyIsSet(
    evt: *KeyboardEvent,
    comptime key: enum { ctrl, alt, shift, meta },
) bool {
    var is_set: bool = false;
    const err = switch (key) {
        .ctrl => c._dom_keyboard_event_get_ctrl_key(evt, &is_set),
        .alt => c._dom_keyboard_event_get_alt_key(evt, &is_set),
        .shift => c._dom_keyboard_event_get_shift_key(evt, &is_set),
        .meta => c._dom_keyboard_event_get_meta_key(evt, &is_set),
    };
    // None of the earlier can fail.
    std.debug.assert(err == c.DOM_NO_ERR);

    return is_set;
}

pub const KeyboardEventOpts = struct {
    key: []const u8 = "",
    code: []const u8 = "",
    location: LocationCode = .standard,
    repeat: bool = false,
    bubbles: bool = false,
    cancelable: bool = false,
    is_composing: bool = false,
    ctrl_key: bool = false,
    alt_key: bool = false,
    shift_key: bool = false,
    meta_key: bool = false,

    pub const LocationCode = enum(u32) {
        standard = c.DOM_KEY_LOCATION_STANDARD,
        left = c.DOM_KEY_LOCATION_LEFT,
        right = c.DOM_KEY_LOCATION_RIGHT,
        numpad = c.DOM_KEY_LOCATION_NUMPAD,
        mobile = 0x04, // Non-standard, deprecated.
        joystick = 0x05, // Non-standard, deprecated.
    };
};

pub fn keyboardEventInit(evt: *KeyboardEvent, typ: []const u8, opts: KeyboardEventOpts) !void {
    const s = try strFromData(typ);
    const err = c._dom_keyboard_event_init(
        evt,
        s,
        opts.bubbles,
        opts.cancelable,
        null, // dom_abstract_view* ?
        try strFromData(opts.key),
        try strFromData(opts.code),
        @intFromEnum(opts.location),
        opts.ctrl_key,
        opts.shift_key,
        opts.alt_key,
        opts.meta_key,
        opts.repeat, // repease
        opts.is_composing, // is_composiom
    );
    try DOMErr(err);
}

pub fn keyboardEventGetKey(evt: *KeyboardEvent) ![]const u8 {
    var s: ?*String = null;
    _ = c._dom_keyboard_event_get_key(evt, &s);
    return strToData(s.?);
}

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
    return @as(*Node, @ptrCast(@alignCast(n)));
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
    var s: ?*String = null;
    const err = nodeVtable(node).dom_node_get_local_name.?(node, &s);
    try DOMErr(err);
    if (s == null) return "";
    var s_lower: ?*String = null;
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
    var res: ?*Node = null;
    const err = nodeVtable(node).dom_node_get_first_child.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeLastChild(node: *Node) !?*Node {
    var res: ?*Node = null;
    const err = nodeVtable(node).dom_node_get_last_child.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeNextSibling(node: *Node) !?*Node {
    var res: ?*Node = null;
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
    var res: ?*Node = null;
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
    var res: ?*Node = null;
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
    var s: ?*String = null;
    const err = nodeVtable(node).dom_node_get_node_name.?(node, &s);
    try DOMErr(err);
    if (s == null) return "";
    return strToData(s.?);
}

pub fn nodeOwnerDocument(node: *Node) !?*Document {
    var doc: ?*Document = null;
    const err = nodeVtable(node).dom_node_get_owner_document.?(node, &doc);
    try DOMErr(err);
    return doc;
}

pub fn nodeValue(node: *Node) !?[]const u8 {
    var s: ?*String = null;
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
    var s: ?*String = null;
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

pub fn nodeGetChildNodes(node: *Node) !*NodeList {
    var nlist: ?*NodeList = null;
    const err = nodeVtable(node).dom_node_get_child_nodes.?(node, &nlist);
    try DOMErr(err);
    return nlist.?;
}

pub fn nodeGetRootNode(node: *Node) !*Node {
    var root = node;
    while (true) {
        const parent = try nodeParentNode(root);
        if (parent) |parent_| {
            root = parent_;
        } else break;
    }
    return root;
}

pub fn nodeAppendChild(node: *Node, child: *Node) !*Node {
    var res: ?*Node = null;
    const err = nodeVtable(node).dom_node_append_child.?(node, child, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeCloneNode(node: *Node, is_deep: bool) !*Node {
    var res: ?*Node = null;
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
    var res: ?*Node = null;
    const err = nodeVtable(node).dom_node_insert_before.?(node, new_node, ref_node, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeIsDefaultNamespace(node: *Node, namespace_: ?[]const u8) !bool {
    const s = if (namespace_) |n| try strFromData(n) else null;
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
    var s: ?*String = null;
    const err = nodeVtable(node).dom_node_lookup_prefix.?(node, try strFromData(namespace), &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeLookupNamespaceURI(node: *Node, prefix_: ?[]const u8) !?[]const u8 {
    var s: ?*String = null;
    const prefix: ?*String = if (prefix_) |p| try strFromData(p) else null;
    const err = nodeVtable(node).dom_node_lookup_namespace.?(node, prefix, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeNormalize(node: *Node) !void {
    const err = nodeVtable(node).dom_node_normalize.?(node);
    try DOMErr(err);
}

pub fn nodeRemoveChild(node: *Node, child: *Node) !*Node {
    var res: ?*Node = null;
    const err = nodeVtable(node).dom_node_remove_child.?(node, child, &res);
    try DOMErr(err);
    return res.?;
}

pub fn nodeReplaceChild(node: *Node, new_child: *Node, old_child: *Node) !*Node {
    var res: ?*Node = null;
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

pub fn nodeGetAttributes(node: *Node) !?*NamedNodeMap {
    var res: ?*NamedNodeMap = null;
    const err = nodeVtable(node).dom_node_get_attributes.?(node, &res);
    try DOMErr(err);
    return res;
}

pub fn nodeGetNamespace(node: *Node) !?[]const u8 {
    var s: ?*String = null;
    const err = nodeVtable(node).dom_node_get_namespace.?(node, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeGetPrefix(node: *Node) !?[]const u8 {
    var s: ?*String = null;
    const err = nodeVtable(node).dom_node_get_prefix.?(node, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeGetEmbedderData(node: *Node) ?*anyopaque {
    return c._dom_node_get_embedder_data(node);
}

pub fn nodeSetEmbedderData(node: *Node, data: *anyopaque) void {
    c._dom_node_set_embedder_data(node, data);
}

pub fn nodeGetElementById(node: *Node, id: []const u8) !?*Element {
    var el: ?*Element = null;
    const str_id = try strFromData(id);
    try DOMErr(c._dom_find_element_by_id(node, str_id, &el));
    return el;
}

// nodeToElement is an helper to convert a node to an element.
pub inline fn nodeToElement(node: *Node) *Element {
    return @as(*Element, @ptrCast(node));
}

// nodeToDocument is an helper to convert a node to an document.
pub inline fn nodeToDocument(node: *Node) *Document {
    return @as(*Document, @ptrCast(node));
}

// Combination of nodeToElement + elementTag
pub fn nodeHTMLGetTagType(node: *Node) !?Tag {
    if (try nodeType(node) != .element) {
        return null;
    }

    return try elementTag(@ptrCast(node));
}

// CharacterData
pub const CharacterData = c.dom_characterdata;

fn characterDataVtable(data: *CharacterData) c.dom_characterdata_vtable {
    return getVtable(c.dom_characterdata_vtable, CharacterData, data);
}

pub inline fn characterDataToNode(cdata: *CharacterData) *Node {
    return @as(*Node, @ptrCast(@alignCast(cdata)));
}

pub fn characterDataData(cdata: *CharacterData) ![]const u8 {
    var s: ?*String = null;
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
    var s: ?*String = null;
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
    var s: ?*String = null;
    const err = textVtable(text).dom_text_get_whole_text.?(text, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn textSplitText(text: *Text, offset: u32) !*Text {
    var res: ?*Text = null;
    const err = textVtable(text).dom_text_split_text.?(text, offset, &res);
    try DOMErr(err);
    return res.?;
}

// Comment
pub const Comment = c.dom_comment;

// ProcessingInstruction
pub const ProcessingInstruction = c.dom_processing_instruction;

// processingInstructionToNode is an helper to convert an ProcessingInstruction to a node.
pub inline fn processingInstructionToNode(pi: *ProcessingInstruction) *Node {
    return @as(*Node, @ptrCast(@alignCast(pi)));
}

pub fn processInstructionCopy(pi: *ProcessingInstruction) !*ProcessingInstruction {
    var res: ?*Node = null;
    const err = c._dom_pi_copy(processingInstructionToNode(pi), &res);
    try DOMErr(err);
    return @as(*ProcessingInstruction, @ptrCast(res.?));
}

// Attribute
pub const Attribute = c.dom_attr;

fn attributeVtable(a: *Attribute) c.dom_attr_vtable {
    return getVtable(c.dom_attr_vtable, Attribute, a);
}

pub fn attributeGetName(a: *Attribute) ![]const u8 {
    var s: ?*String = null;
    const err = attributeVtable(a).dom_attr_get_name.?(a, &s);
    try DOMErr(err);

    return strToData(s.?);
}

pub fn attributeGetValue(a: *Attribute) !?[]const u8 {
    var s: ?*String = null;
    const err = attributeVtable(a).dom_attr_get_value.?(a, &s);
    try DOMErr(err);
    if (s == null) return null;

    return strToData(s.?);
}

pub fn attributeSetValue(a: *Attribute, v: []const u8) !void {
    // if the attribute has no owner/parent, the function crashes.
    if (try attributeGetOwnerElement(a) == null) {
        return DOMError.NotSupported;
    }

    const err = attributeVtable(a).dom_attr_set_value.?(a, try strFromData(v));
    try DOMErr(err);
}

pub fn attributeGetOwnerElement(a: *Attribute) !?*Element {
    var elt: ?*Element = null;
    const err = attributeVtable(a).dom_attr_get_owner_element.?(a, &elt);
    try DOMErr(err);
    if (elt == null) return null;

    return elt.?;
}

// attributeToNode is an helper to convert an attribute to a node.
pub inline fn attributeToNode(a: *Attribute) *Node {
    return @as(*Node, @ptrCast(@alignCast(a)));
}

// Element
pub const Element = c.dom_element;

fn elementVtable(elem: *Element) c.dom_element_vtable {
    return getVtable(c.dom_element_vtable, Element, elem);
}

pub fn elementTag(elem: *Element) !Tag {
    const tagname = try elementGetTagName(elem) orelse return .undef;
    return Tag.fromString(tagname) catch .undef;
}

pub fn elementGetTagName(elem: *Element) !?[]const u8 {
    var s: ?*String = null;
    const err = elementVtable(elem).dom_element_get_tag_name.?(elem, &s);
    try DOMErr(err);
    if (s == null) return null;

    return strToData(s.?);
}

pub fn elementGetAttribute(elem: *Element, name: []const u8) !?[]const u8 {
    var s: ?*String = null;
    const err = elementVtable(elem).dom_element_get_attribute.?(elem, try strFromData(name), &s);
    try DOMErr(err);
    if (s == null) return null;

    return strToData(s.?);
}

pub fn elementGetAttributeNS(elem: *Element, ns: []const u8, name: []const u8) !?[]const u8 {
    var s: ?*String = null;
    const err = elementVtable(elem).dom_element_get_attribute_ns.?(
        elem,
        try strFromData(ns),
        try strFromData(name),
        &s,
    );
    try DOMErr(err);
    if (s == null) return null;

    return strToData(s.?);
}

pub fn elementSetAttribute(elem: *Element, qname: []const u8, value: []const u8) !void {
    const dom_str = try strFromData(qname);
    if (!c._dom_validate_name(dom_str)) {
        return error.InvalidCharacterError;
    }

    const err = elementVtable(elem).dom_element_set_attribute.?(
        elem,
        dom_str,
        try strFromData(value),
    );
    try DOMErr(err);
}

pub fn elementSetAttributeNS(
    elem: *Element,
    ns: []const u8,
    qname: []const u8,
    value: []const u8,
) !void {
    const dom_str = try strFromData(qname);
    if (!c._dom_validate_name(dom_str)) {
        return error.InvalidCharacterError;
    }

    const err = elementVtable(elem).dom_element_set_attribute_ns.?(
        elem,
        try strFromData(ns),
        dom_str,
        try strFromData(value),
    );
    try DOMErr(err);
}

pub fn elementRemoveAttribute(elem: *Element, qname: []const u8) !void {
    const err = elementVtable(elem).dom_element_remove_attribute.?(elem, try strFromData(qname));
    try DOMErr(err);
}

pub fn elementRemoveAttributeNS(elem: *Element, ns: []const u8, qname: []const u8) !void {
    const err = elementVtable(elem).dom_element_remove_attribute_ns.?(
        elem,
        try strFromData(ns),
        try strFromData(qname),
    );
    try DOMErr(err);
}

pub fn elementHasAttribute(elem: *Element, qname: []const u8) !bool {
    var res: bool = undefined;
    const err = elementVtable(elem).dom_element_has_attribute.?(elem, try strFromData(qname), &res);
    try DOMErr(err);
    return res;
}

pub fn elementHasAttributeNS(elem: *Element, ns: []const u8, qname: []const u8) !bool {
    var res: bool = undefined;
    const err = elementVtable(elem).dom_element_has_attribute_ns.?(elem, if (ns.len == 0) null else try strFromData(ns), try strFromData(qname), &res);
    try DOMErr(err);
    return res;
}

pub fn elementGetAttributeNode(elem: *Element, name: []const u8) !?*Attribute {
    var a: ?*Attribute = null;
    const err = elementVtable(elem).dom_element_get_attribute_node.?(elem, try strFromData(name), &a);
    try DOMErr(err);
    return a;
}

pub fn elementGetAttributeNodeNS(elem: *Element, ns: []const u8, name: []const u8) !?*Attribute {
    var a: ?*Attribute = null;
    const err = elementVtable(elem).dom_element_get_attribute_node_ns.?(
        elem,
        if (ns.len == 0) null else try strFromData(ns),
        try strFromData(name),
        &a,
    );
    try DOMErr(err);
    return a;
}

pub fn elementSetAttributeNode(elem: *Element, attr: *Attribute) !?*Attribute {
    var a: ?*Attribute = null;
    const err = elementVtable(elem).dom_element_set_attribute_node.?(elem, attr, &a);
    try DOMErr(err);
    return a;
}

pub fn elementSetAttributeNodeNS(elem: *Element, attr: *Attribute) !?*Attribute {
    var a: ?*Attribute = null;
    const err = elementVtable(elem).dom_element_set_attribute_node_ns.?(elem, attr, &a);
    try DOMErr(err);
    return a;
}

pub fn elementRemoveAttributeNode(elem: *Element, attr: *Attribute) !*Attribute {
    var a: ?*Attribute = null;
    const err = elementVtable(elem).dom_element_remove_attribute_node.?(elem, attr, &a);
    try DOMErr(err);
    return a.?;
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
    return @as(*Node, @ptrCast(@alignCast(e)));
}

// TokenList
pub const TokenList = c.dom_tokenlist;

pub fn tokenListCreate(elt: *Element, attr: []const u8) !*TokenList {
    var list: ?*TokenList = null;
    const err = c.dom_tokenlist_create(elt, try strFromData(attr), &list);
    try DOMErr(err);
    return list.?;
}

pub fn tokenListGetLength(l: *TokenList) !u32 {
    var res: u32 = undefined;
    const err = c.dom_tokenlist_get_length(l, &res);
    try DOMErr(err);
    return res;
}

pub fn tokenListItem(l: *TokenList, index: u32) !?[]const u8 {
    var res: ?*String = null;
    const err = c._dom_tokenlist_item(l, index, &res);
    try DOMErr(err);
    if (res == null) return null;
    return strToData(res.?);
}

pub fn tokenListContains(l: *TokenList, token: []const u8) !bool {
    var res: bool = undefined;
    const err = c.dom_tokenlist_contains(l, try strFromData(token), &res);
    try DOMErr(err);
    return res;
}

pub fn tokenListAdd(l: *TokenList, token: []const u8) !void {
    const err = c.dom_tokenlist_add(l, try strFromData(token));
    try DOMErr(err);
}

pub fn tokenListRemove(l: *TokenList, token: []const u8) !void {
    const err = c.dom_tokenlist_remove(l, try strFromData(token));
    try DOMErr(err);
}

pub fn tokenListGetValue(l: *TokenList) !?[]const u8 {
    var res: ?*String = null;
    const err = c.dom_tokenlist_get_value(l, &res);
    try DOMErr(err);
    if (res == null) return null;
    return strToData(res.?);
}

pub fn tokenListSetValue(l: *TokenList, value: []const u8) !void {
    const err = c.dom_tokenlist_set_value(l, try strFromData(value));
    try DOMErr(err);
}

// ElementHTML
pub const ElementHTML = c.dom_html_element;

fn elementHTMLVtable(elem_html: *ElementHTML) c.dom_html_element_vtable {
    return getVtable(c.dom_html_element_vtable, ElementHTML, elem_html);
}

// HTMLScriptElement

// scriptToElt is an helper to convert an script to an element.
pub inline fn scriptToElt(s: *Script) *Element {
    return @as(*Element, @ptrCast(@alignCast(s)));
}

// HTMLAnchorElement

// anchorToNode is an helper to convert an anchor to a node.
pub inline fn anchorToNode(a: *Anchor) *Node {
    return @as(*Node, @ptrCast(@alignCast(a)));
}

pub fn anchorGetTarget(a: *Anchor) ![]const u8 {
    var res: ?*String = null;
    const err = c.dom_html_anchor_element_get_target(a, &res);
    try DOMErr(err);
    if (res == null) return "";
    return strToData(res.?);
}

pub fn anchorSetTarget(a: *Anchor, target: []const u8) !void {
    const err = c.dom_html_anchor_element_set_target(a, try strFromData(target));
    try DOMErr(err);
}

pub fn anchorGetHref(a: *Anchor) ![]const u8 {
    var res: ?*String = null;
    const err = c.dom_html_anchor_element_get_href(a, &res);
    try DOMErr(err);
    if (res == null) return "";
    return strToData(res.?);
}

pub fn anchorSetHref(a: *Anchor, href: []const u8) !void {
    const err = c.dom_html_anchor_element_set_href(a, try strFromData(href));
    try DOMErr(err);
}

pub fn anchorGetHrefLang(a: *Anchor) ![]const u8 {
    var res: ?*String = null;
    const err = c.dom_html_anchor_element_get_hreflang(a, &res);
    try DOMErr(err);
    if (res == null) return "";
    return strToData(res.?);
}

pub fn anchorSetHrefLang(a: *Anchor, href: []const u8) !void {
    const err = c.dom_html_anchor_element_set_hreflang(a, try strFromData(href));
    try DOMErr(err);
}

pub fn anchorGetType(a: *Anchor) ![]const u8 {
    var res: ?*String = null;
    const err = c.dom_html_anchor_element_get_type(a, &res);
    try DOMErr(err);
    if (res == null) return "";
    return strToData(res.?);
}

pub fn anchorSetType(a: *Anchor, t: []const u8) !void {
    const err = c.dom_html_anchor_element_set_type(a, try strFromData(t));
    try DOMErr(err);
}

pub fn anchorGetRel(a: *Anchor) ![]const u8 {
    var res: ?*String = null;
    const err = c.dom_html_anchor_element_get_rel(a, &res);
    try DOMErr(err);
    if (res == null) return "";
    return strToData(res.?);
}

pub fn anchorSetRel(a: *Anchor, rel: []const u8) !void {
    const err = c.dom_html_anchor_element_set_rel(a, try strFromData(rel));
    try DOMErr(err);
}

// HTMLLinkElement

pub fn linkGetHref(link: *Link) ![]const u8 {
    var res: ?*String = null;
    const err = c.dom_html_link_element_get_href(link, &res);
    try DOMErr(err);
    if (res == null) return "";
    return strToData(res.?);
}

pub fn linkSetHref(link: *Link, href: []const u8) !void {
    const err = c.dom_html_link_element_set_href(link, try strFromData(href));
    try DOMErr(err);
}

// ElementsHTML

pub const MediaElement = struct { base: *c.dom_html_element };

pub const Unknown = struct { base: *c.dom_html_element };
pub const Anchor = c.dom_html_anchor_element;
pub const Applet = c.dom_html_applet_element;
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
pub const Slot = c.dom_html_slot_element;
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
pub const HTMLCollection = c.dom_html_collection;
pub const OptionCollection = c.dom_html_options_collection;

// Document Fragment
pub const DocumentFragment = c.dom_document_fragment;

pub inline fn documentFragmentToNode(doc: *DocumentFragment) *Node {
    return @as(*Node, @ptrCast(@alignCast(doc)));
}

pub fn documentFragmentGetHost(frag: *DocumentFragment) ?*Node {
    var node: ?*NodeExternal = null;
    c._dom_document_fragment_get_host(frag, &node);
    return if (node) |n| @ptrCast(n) else null;
}
pub fn documentFragmentSetHost(frag: *DocumentFragment, host: *Node) void {
    c._dom_document_fragment_set_host(frag, host);
}

// Document Position

pub const DocumentPosition = enum(u32) {
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
    var s: ?*String = null;
    const err = documentTypeVtable(dt).dom_document_type_get_name.?(dt, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentTypeGetPublicId(dt: *DocumentType) ![]const u8 {
    var s: ?*String = null;
    const err = documentTypeVtable(dt).dom_document_type_get_public_id.?(dt, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentTypeGetSystemId(dt: *DocumentType) ![]const u8 {
    var s: ?*String = null;
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
    var doc: ?*Document = null;

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
    var dt: ?*DocumentType = null;
    const err = c.dom_implementation_create_document_type(qname.ptr, publicId.ptr, systemId.ptr, &dt);
    try DOMErr(err);
    return dt.?;
}

pub inline fn domImplementationCreateHTMLDocument(title: ?[]const u8) !*DocumentHTML {
    const doc_html = try documentCreateDocument(title);
    const doc = documentHTMLToDocument(doc_html);

    // add hierarchy: html, head, body.
    const html = try documentCreateElement(doc, "html");
    _ = try nodeAppendChild(documentToNode(doc), elementToNode(html));

    const head = try documentCreateElement(doc, "head");
    _ = try nodeAppendChild(elementToNode(html), elementToNode(head));

    if (title) |t| {
        const htitle = try documentCreateElement(doc, "title");
        const txt = try documentCreateTextNode(doc, t);
        _ = try nodeAppendChild(elementToNode(htitle), @as(*Node, @ptrCast(@alignCast(txt))));
        _ = try nodeAppendChild(elementToNode(head), elementToNode(htitle));
    }

    const body = try documentCreateElement(doc, "body");
    _ = try nodeAppendChild(elementToNode(html), elementToNode(body));

    return doc_html;
}

// Document
pub const Document = c.dom_document;

fn documentVtable(doc: *Document) c.dom_document_vtable {
    return getVtable(c.dom_document_vtable, Document, doc);
}

pub inline fn documentToNode(doc: *Document) *Node {
    return @as(*Node, @ptrCast(@alignCast(doc)));
}

pub inline fn documentGetElementById(doc: *Document, id: []const u8) !?*Element {
    var elem: ?*Element = null;
    const err = documentVtable(doc).dom_document_get_element_by_id.?(doc, try strFromData(id), &elem);
    try DOMErr(err);
    return elem;
}

pub inline fn documentGetElementsByTagName(doc: *Document, tagname: []const u8) !*NodeList {
    var nlist: ?*NodeList = null;
    const err = documentVtable(doc).dom_document_get_elements_by_tag_name.?(doc, try strFromData(tagname), &nlist);
    try DOMErr(err);
    return nlist.?;
}

// documentGetDocumentElement returns the root document element.
pub inline fn documentGetDocumentElement(doc: *Document) !?*Element {
    var elem: ?*Element = null;
    const err = documentVtable(doc).dom_document_get_document_element.?(doc, &elem);
    try DOMErr(err);
    if (elem == null) return null;
    return elem.?;
}

pub inline fn documentGetDocumentURI(doc: *Document) ![]const u8 {
    var s: ?*String = null;
    const err = documentVtable(doc).dom_document_get_uri.?(doc, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn documentSetDocumentURI(doc: *Document, uri: []const u8) !void {
    const err = documentVtable(doc).dom_document_set_uri.?(doc, try strFromData(uri));
    try DOMErr(err);
}

pub inline fn documentGetInputEncoding(doc: *Document) ![]const u8 {
    var s: ?*String = null;
    const err = documentVtable(doc).dom_document_get_input_encoding.?(doc, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentSetInputEncoding(doc: *Document, enc: []const u8) !void {
    const err = documentVtable(doc).dom_document_set_input_encoding.?(doc, try strFromData(enc));
    try DOMErr(err);
}

pub inline fn documentCreateDocument(title: ?[]const u8) !*DocumentHTML {
    var doc: ?*Document = null;
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
    const doc_html = @as(*DocumentHTML, @ptrCast(doc.?));
    if (title) |t| try documentHTMLSetTitle(doc_html, t);
    return doc_html;
}

fn documentCreateHTMLElement(doc: *Document, tag_name: []const u8) !*Element {
    std.debug.assert(doc.is_html);

    var elem: ?*Element = null;
    const err = c._dom_html_document_create_element(doc, try strFromData(tag_name), &elem);
    try DOMErr(err);
    return elem.?;
}

pub fn documentCreateElement(doc: *Document, tag_name: []const u8) !*Element {
    if (doc.is_html) {
        return documentCreateHTMLElement(doc, tag_name);
    }

    var elem: ?*Element = null;
    const err = documentVtable(doc).dom_document_create_element.?(doc, try strFromData(tag_name), &elem);
    try DOMErr(err);
    return elem.?;
}

fn documentCreateHTMLElementNS(doc: *Document, ns: []const u8, tag_name: []const u8) !*Element {
    std.debug.assert(doc.is_html);

    var elem: ?*Element = null;
    const err = c._dom_html_document_create_element_ns(
        doc,
        try strFromData(ns),
        try strFromData(tag_name),
        &elem,
    );
    try DOMErr(err);
    return elem.?;
}

pub fn documentCreateElementNS(doc: *Document, ns: []const u8, tag_name: []const u8) !*Element {
    if (doc.is_html) {
        return documentCreateHTMLElementNS(doc, ns, tag_name);
    }

    var elem: ?*Element = null;
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
    var dt: ?*DocumentType = null;
    const err = documentVtable(doc).dom_document_get_doctype.?(doc, &dt);
    try DOMErr(err);
    return dt;
}

pub inline fn documentCreateDocumentFragment(doc: *Document) !*DocumentFragment {
    var df: ?*DocumentFragment = null;
    const err = documentVtable(doc).dom_document_create_document_fragment.?(doc, &df);
    try DOMErr(err);
    return df.?;
}

pub inline fn documentCreateTextNode(doc: *Document, s: []const u8) !*Text {
    var txt: ?*Text = null;
    const err = documentVtable(doc).dom_document_create_text_node.?(doc, try strFromData(s), &txt);
    try DOMErr(err);
    return txt.?;
}

pub inline fn documentCreateCDATASection(doc: *Document, s: []const u8) !*CDATASection {
    var cdata: ?*CDATASection = null;
    const err = documentVtable(doc).dom_document_create_cdata_section.?(doc, try strFromData(s), &cdata);
    try DOMErr(err);
    return cdata.?;
}

pub inline fn documentCreateComment(doc: *Document, s: []const u8) !*Comment {
    var com: ?*Comment = null;
    const err = documentVtable(doc).dom_document_create_comment.?(doc, try strFromData(s), &com);
    try DOMErr(err);
    return com.?;
}

pub inline fn documentCreateProcessingInstruction(doc: *Document, target: []const u8, data: []const u8) !*ProcessingInstruction {
    var pi: ?*ProcessingInstruction = null;
    const err = documentVtable(doc).dom_document_create_processing_instruction.?(
        doc,
        try strFromData(target),
        try strFromData(data),
        &pi,
    );
    try DOMErr(err);
    return pi.?;
}

pub inline fn documentImportNode(doc: *Document, node: *Node, deep: bool) !*Node {
    var res: NodeExternal = undefined;
    const nodeext = toNodeExternal(Node, node);
    const err = documentVtable(doc).dom_document_import_node.?(doc, nodeext, deep, &res);
    try DOMErr(err);
    return @as(*Node, @ptrCast(@alignCast(res)));
}

pub inline fn documentAdoptNode(doc: *Document, node: *Node) !*Node {
    var res: NodeExternal = undefined;
    const nodeext = toNodeExternal(Node, node);
    const err = documentVtable(doc).dom_document_adopt_node.?(doc, nodeext, &res);
    try DOMErr(err);
    return @as(*Node, @ptrCast(@alignCast(res)));
}

pub inline fn documentCreateAttribute(doc: *Document, name: []const u8) !*Attribute {
    var attr: ?*Attribute = null;
    const err = documentVtable(doc).dom_document_create_attribute.?(doc, try strFromData(name), &attr);
    try DOMErr(err);
    return attr.?;
}

pub inline fn documentCreateAttributeNS(doc: *Document, ns: []const u8, qname: []const u8) !*Attribute {
    var attr: ?*Attribute = null;
    const err = documentVtable(doc).dom_document_create_attribute_ns.?(
        doc,
        try strFromData(ns),
        try strFromData(qname),
        &attr,
    );
    try DOMErr(err);
    return attr.?;
}

pub fn documentSetScriptAddedCallback(
    doc: *Document,
    ctx: *anyopaque,
    callback: c.dom_script_added_callback,
) void {
    c._dom_document_set_script_added_callback(doc, ctx, callback);
}

// DocumentHTML
pub const DocumentHTML = c.dom_html_document;

// documentHTMLToNode is an helper to convert a documentHTML to an node.
pub inline fn documentHTMLToNode(doc: *DocumentHTML) *Node {
    return @as(*Node, @ptrCast(@alignCast(doc)));
}

fn documentHTMLVtable(doc_html: *DocumentHTML) c.dom_html_document_vtable {
    return getVtable(c.dom_html_document_vtable, DocumentHTML, doc_html);
}

const ParserError = error{
    Reprocess,
    EncodingChange,
    Paused,
    NoMemory,
    Dom,
    Hubbub,
    BadParameter,
    BadEncoding,
    Invalid,
    FileNotFound,
    NeedData,
    Unknown,
};

const HubbubErr = c.hubbub_error;

fn parserErr(err: HubbubErr) ParserError!void {
    return switch (err) {
        c.DOM_HUBBUB_OK => {},
        c.DOM_HUBBUB_NOMEM => ParserError.NoMemory,
        c.DOM_HUBBUB_BADPARM => ParserError.BadParameter,
        c.DOM_HUBBUB_DOM => ParserError.Dom,
        c.DOM_HUBBUB_HUBBUB_ERR => ParserError.Hubbub,
        c.DOM_HUBBUB_HUBBUB_ERR_PAUSED => ParserError.Paused,
        c.DOM_HUBBUB_HUBBUB_ERR_ENCODINGCHANGE => ParserError.EncodingChange,
        c.DOM_HUBBUB_HUBBUB_ERR_NOMEM => ParserError.NoMemory,
        c.DOM_HUBBUB_HUBBUB_ERR_BADPARM => ParserError.BadParameter,
        c.DOM_HUBBUB_HUBBUB_ERR_INVALID => ParserError.Invalid,
        c.DOM_HUBBUB_HUBBUB_ERR_FILENOTFOUND => ParserError.FileNotFound,
        c.DOM_HUBBUB_HUBBUB_ERR_NEEDDATA => ParserError.NeedData,
        c.DOM_HUBBUB_HUBBUB_ERR_BADENCODING => ParserError.BadEncoding,
        c.DOM_HUBBUB_HUBBUB_ERR_UNKNOWN => ParserError.Unknown,
        else => unreachable,
    };
}

pub const Parser = struct {
    html_doc: *DocumentHTML,
    parser: *c.dom_hubbub_parser,

    pub fn init(encoding: ?[:0]const u8) !Parser {
        var params = parseParams(encoding);
        var doc: ?*c.dom_document = undefined;
        var parser: ?*c.dom_hubbub_parser = undefined;

        try parserErr(c.dom_hubbub_parser_create(&params, &parser, &doc));
        return .{
            .parser = parser.?,
            .html_doc = @ptrCast(doc.?),
        };
    }

    pub fn deinit(self: *Parser) void {
        c.dom_hubbub_parser_destroy(self.parser);
    }

    pub fn process(self: *Parser, data: []const u8) !void {
        try parserErr(c.dom_hubbub_parser_parse_chunk(self.parser, data.ptr, data.len));
    }
};

// documentHTMLParseFromStr parses the given HTML string.
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromStr(str: []const u8) !*DocumentHTML {
    var fbs = std.io.fixedBufferStream(str);
    return try documentHTMLParse(fbs.reader(), "UTF-8");
}

pub fn documentHTMLParse(reader: anytype, enc: ?[:0]const u8) !*DocumentHTML {
    var parser = try Parser.init(enc);
    defer parser.deinit();
    try parseData(parser.parser, reader);
    return parser.html_doc;
}

pub fn documentParseFragmentFromStr(self: *Document, str: []const u8) !*DocumentFragment {
    var fbs = std.io.fixedBufferStream(str);
    return try documentParseFragment(self, fbs.reader(), "UTF-8");
}

pub fn documentParseFragment(self: *Document, reader: anytype, enc: ?[:0]const u8) !*DocumentFragment {
    var parser: ?*c.dom_hubbub_parser = undefined;
    var fragment: ?*c.dom_document_fragment = undefined;
    var err: c.hubbub_error = undefined;
    var params = parseParams(enc);

    err = c.dom_hubbub_fragment_parser_create(&params, self, &parser, &fragment);
    try parserErr(err);
    defer c.dom_hubbub_parser_destroy(parser);

    try parseData(parser.?, reader);

    return @as(*DocumentFragment, @ptrCast(fragment.?));
}

fn parseParams(enc: ?[:0]const u8) c.dom_hubbub_parser_params {
    return .{
        .enc = enc orelse null,
        .fix_enc = true,
        .msg = null,
        .script = null,
        .enable_script = false,
        .ctx = null,
        .daf = null,
    };
}

fn parseData(parser: *c.dom_hubbub_parser, reader: anytype) !void {
    var err: c.hubbub_error = undefined;
    const TI = @typeInfo(@TypeOf(reader));
    if (TI == .pointer and @hasDecl(TI.pointer.child, "next")) {
        while (try reader.next()) |data| {
            err = c.dom_hubbub_parser_parse_chunk(parser, data.ptr, data.len);
            try parserErr(err);
        }
    } else {
        var buffer: [1024]u8 = undefined;
        var ln = buffer.len;
        while (ln > 0) {
            ln = try reader.read(&buffer);
            err = c.dom_hubbub_parser_parse_chunk(parser, &buffer, ln);
            // TODO handle encoding change error return.
            // When the HTML contains a META tag with a different encoding than the
            // original one, a c.DOM_HUBBUB_HUBBUB_ERR_ENCODINGCHANGE error is
            // returned.
            // In this case, we must restart the parsing with the new detected
            // encoding. The detected encoding is stored in the document and we can
            // get it with documentGetInputEncoding().
            try parserErr(err);
        }
    }
    err = c.dom_hubbub_parser_completed(parser);
    try parserErr(err);
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
    var body: ?*ElementHTML = null;
    const err = documentHTMLVtable(doc_html).get_body.?(doc_html, &body);
    try DOMErr(err);
    if (body == null) return null;
    return @as(*Body, @ptrCast(body.?));
}

pub inline fn bodyToElement(body: *Body) *Element {
    return @as(*Element, @ptrCast(@alignCast(body)));
}

pub inline fn documentHTMLSetBody(doc_html: *DocumentHTML, elt: ?*ElementHTML) !void {
    const err = documentHTMLVtable(doc_html).set_body.?(doc_html, elt);
    try DOMErr(err);
}

pub inline fn documentHTMLGetReferrer(doc: *DocumentHTML) ![]const u8 {
    var s: ?*String = null;
    const err = documentHTMLVtable(doc).get_referrer.?(doc, &s);
    try DOMErr(err);
    if (s == null) return "";
    return strToData(s.?);
}

pub inline fn documentHTMLGetTitle(doc: *DocumentHTML) ![]const u8 {
    var s: ?*String = null;
    const err = documentHTMLVtable(doc).get_title.?(doc, &s);
    try DOMErr(err);
    if (s == null) return "";
    return strToData(s.?);
}

pub inline fn documentHTMLSetTitle(doc: *DocumentHTML, v: []const u8) !void {
    const err = documentHTMLVtable(doc).set_title.?(doc, try strFromData(v));
    try DOMErr(err);
}

pub fn documentHTMLSetCurrentScript(doc: *DocumentHTML, script: ?*Script) !void {
    var s: ?*ElementHTML = null;
    if (script != null) s = @ptrCast(@alignCast(script.?));
    const err = documentHTMLVtable(doc).set_current_script.?(doc, s);
    try DOMErr(err);
}

pub fn documentHTMLGetCurrentScript(doc: *DocumentHTML) !?*Script {
    var elem: ?*ElementHTML = null;
    const err = documentHTMLVtable(doc).get_current_script.?(doc, &elem);
    try DOMErr(err);
    if (elem == null) return null;
    return @ptrCast(elem.?);
}

pub fn documentHTMLSetLocation(T: type, doc: *DocumentHTML, location: *T) !void {
    const l = @as(*anyopaque, @ptrCast(location));
    const err = documentHTMLVtable(doc).set_location.?(doc, l);
    try DOMErr(err);
}

pub fn documentHTMLGetLocation(T: type, doc: *DocumentHTML) !?*T {
    var l: ?*anyopaque = null;
    const err = documentHTMLVtable(doc).get_location.?(doc, &l);
    try DOMErr(err);

    if (l == null) return null;

    const ptr: *align(@alignOf(*T)) anyopaque = @alignCast(l.?);
    return @as(*T, @ptrCast(ptr));
}

pub fn validateName(name: []const u8) !bool {
    return c._dom_validate_name(try strFromData(name));
}

// Form
pub fn formElementSubmit(form: *Form) !void {
    const err = c.dom_html_form_element_submit(form);
    try DOMErr(err);
}

pub fn formElementReset(form: *Form) !void {
    const err = c.dom_html_form_element_reset(form);
    try DOMErr(err);
}

pub fn formGetCollection(form: *Form) !*HTMLCollection {
    var collection: ?*HTMLCollection = null;
    const err = c.dom_html_form_element_get_elements(form, &collection);
    try DOMErr(err);
    return collection.?;
}

// TextArea
pub fn textareaGetValue(textarea: *TextArea) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_text_area_element_get_value(textarea, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}

pub fn textareaSetValue(textarea: *TextArea, value: []const u8) !void {
    const err = c.dom_html_text_area_element_set_value(textarea, try strFromData(value));
    try DOMErr(err);
}

// Select
pub fn selectGetOptions(select: *Select) !*OptionCollection {
    var collection: ?*OptionCollection = null;
    const err = c.dom__html_select_element_get_options(select, &collection);
    try DOMErr(err);
    return collection.?;
}

pub fn selectGetDisabled(select: *Select) !bool {
    var disabled: bool = false;
    const err = c.dom_html_select_element_get_disabled(select, &disabled);
    try DOMErr(err);
    return disabled;
}

pub fn selectSetDisabled(select: *Select, disabled: bool) !void {
    const err = c.dom_html_select_element_set_disabled(select, disabled);
    try DOMErr(err);
}

pub fn selectGetMultiple(select: *Select) !bool {
    var multiple: bool = false;
    const err = c.dom_html_select_element_get_multiple(select, &multiple);
    try DOMErr(err);
    return multiple;
}

pub fn selectSetMultiple(select: *Select, multiple: bool) !void {
    const err = c.dom_html_select_element_set_multiple(select, multiple);
    try DOMErr(err);
}

pub fn selectGetName(select: *Select) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_select_element_get_name(select, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}

pub fn selectSetName(select: *Select, name: []const u8) !void {
    const err = c.dom_html_select_element_set_name(select, try strFromData(name));
    try DOMErr(err);
}

pub fn selectGetLength(select: *Select) !u32 {
    var length: u32 = 0;
    const err = c.dom_html_select_element_get_length(select, &length);
    try DOMErr(err);
    return length;
}

pub fn selectGetSelectedIndex(select: *Select) !i32 {
    var index: i32 = 0;
    const err = c.dom_html_select_element_get_selected_index(select, &index);
    try DOMErr(err);
    return index;
}

pub fn selectSetSelectedIndex(select: *Select, index: i32) !void {
    const err = c.dom_html_select_element_set_selected_index(select, index);
    try DOMErr(err);
}

pub fn selectGetForm(select: *Select) !?*Form {
    var form: ?*Form = null;
    const err = c.dom_html_select_element_get_form(select, &form);
    try DOMErr(err);
    return form;
}

// OptionCollection
pub fn optionCollectionGetLength(collection: *OptionCollection) !u32 {
    var len: u32 = 0;
    const err = c.dom_html_options_collection_get_length(collection, &len);
    try DOMErr(err);
    return len;
}

pub fn optionCollectionItem(collection: *OptionCollection, index: u32) !*Option {
    var node: ?*NodeExternal = null;
    const err = c.dom_html_options_collection_item(collection, index, &node);
    try DOMErr(err);
    return @ptrCast(node.?);
}

// Option
pub fn optionGetValue(option: *Option) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_option_element_get_value(option, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}

pub fn optionSetLabel(input: *Option, label: []const u8) !void {
    const err = c.dom_html_option_element_set_label(input, try strFromData(label));
    try DOMErr(err);
}

pub fn optionGetLabel(option: *Option) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_option_element_get_label(option, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}

pub fn optionSetValue(input: *Option, value: []const u8) !void {
    const err = c.dom_html_option_element_set_value(input, try strFromData(value));
    try DOMErr(err);
}

pub fn optionGetSelected(option: *Option) !bool {
    var selected: bool = false;
    const err = c.dom_html_option_element_get_selected(option, &selected);
    try DOMErr(err);
    return selected;
}

pub fn optionSetDisabled(option: *Option, disabled: bool) !void {
    const err = c.dom_html_option_element_set_disabled(option, disabled);
    try DOMErr(err);
}

pub fn optionGetDisabled(option: *Option) !bool {
    var disabled: bool = false;
    const err = c.dom_html_option_element_get_disabled(option, &disabled);
    try DOMErr(err);
    return disabled;
}

pub fn optionSetSelected(option: *Option, selected: bool) !void {
    const err = c.dom_html_option_element_set_selected(option, selected);
    try DOMErr(err);
}

pub fn optionGetText(option: *Option) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_option_element_get_text(option, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}

pub fn optionGetForm(option: *Option) !?*Form {
    var form: ?*Form = null;
    const err = c.dom_html_option_element_get_form(option, &form);
    try DOMErr(err);
    return form;
}

// HtmlCollection
pub fn htmlCollectionGetLength(collection: *HTMLCollection) !u32 {
    var len: u32 = 0;
    const err = c.dom_html_collection_get_length(collection, &len);
    try DOMErr(err);
    return len;
}

pub fn htmlCollectionItem(collection: *HTMLCollection, index: u32) !*Node {
    var node: ?*NodeExternal = null;
    const err = c.dom_html_collection_item(collection, index, &node);
    try DOMErr(err);
    return @ptrCast(node.?);
}

const ulongNegativeOne = 4294967295;

// Image
// Image.name is deprecated
// Image.align is deprecated
// Image.border is deprecated
// Image.longDesc is deprecated
// Image.hspace is deprecated
// Image.vspace is deprecated

pub fn imageGetAlt(image: *Image) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_image_element_get_alt(image, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn imageSetAlt(image: *Image, alt: []const u8) !void {
    const err = c.dom_html_image_element_set_alt(image, try strFromData(alt));
    try DOMErr(err);
}

pub fn imageGetSrc(image: *Image) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_image_element_get_src(image, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn imageSetSrc(image: *Image, src: []const u8) !void {
    const err = c.dom_html_image_element_set_src(image, try strFromData(src));
    try DOMErr(err);
}

pub fn imageGetUseMap(image: *Image) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_image_element_get_use_map(image, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn imageSetUseMap(image: *Image, use_map: []const u8) !void {
    const err = c.dom_html_image_element_set_use_map(image, try strFromData(use_map));
    try DOMErr(err);
}

pub fn imageGetHeight(image: *Image) !u32 {
    var height: u32 = 0;
    const err = c.dom_html_image_element_get_height(image, &height);
    try DOMErr(err);
    if (height == ulongNegativeOne) return 0;
    return height;
}
pub fn imageSetHeight(image: *Image, height: u32) !void {
    const err = c.dom_html_image_element_set_height(image, height);
    try DOMErr(err);
}

pub fn imageGetWidth(image: *Image) !u32 {
    var width: u32 = 0;
    const err = c.dom_html_image_element_get_width(image, &width);
    try DOMErr(err);
    if (width == ulongNegativeOne) return 0;
    return width;
}
pub fn imageSetWidth(image: *Image, width: u32) !void {
    const err = c.dom_html_image_element_set_width(image, width);
    try DOMErr(err);
}

pub fn imageGetIsMap(image: *Image) !bool {
    var is_map: bool = false;
    const err = c.dom_html_image_element_get_is_map(image, &is_map);
    try DOMErr(err);
    return is_map;
}
pub fn imageSetIsMap(image: *Image, is_map: bool) !void {
    const err = c.dom_html_image_element_set_is_map(image, is_map);
    try DOMErr(err);
}

// Input
// - Input.align is deprecated
// - Input.useMap is deprecated
// - HTMLElement.access_key
// - HTMLElement.tabIndex
// TODO methods:
// - HTMLElement.blur
// - HTMLElement.focus
// - select
// - HTMLElement.click

pub fn inputGetDefaultValue(input: *Input) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_input_element_get_default_value(input, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn inputSetDefaultValue(input: *Input, default_value: []const u8) !void {
    const err = c.dom_html_input_element_set_default_value(input, try strFromData(default_value));
    try DOMErr(err);
}

pub fn inputGetDefaultChecked(input: *Input) !bool {
    var default_checked: bool = false;
    const err = c.dom_html_input_element_get_default_checked(input, &default_checked);
    try DOMErr(err);
    return default_checked;
}
pub fn inputSetDefaultChecked(input: *Input, default_checked: bool) !void {
    const err = c.dom_html_input_element_set_default_checked(input, default_checked);
    try DOMErr(err);
}

pub fn inputGetForm(input: *Input) !?*Form {
    var form: ?*Form = null;
    const err = c.dom_html_input_element_get_form(input, &form);
    try DOMErr(err);
    return form;
}

pub fn inputGetAccept(input: *Input) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_input_element_get_accept(input, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn inputSetAccept(input: *Input, accept: []const u8) !void {
    const err = c.dom_html_input_element_set_accept(input, try strFromData(accept));
    try DOMErr(err);
}

pub fn inputGetAlt(input: *Input) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_input_element_get_alt(input, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn inputSetAlt(input: *Input, alt: []const u8) !void {
    const err = c.dom_html_input_element_set_alt(input, try strFromData(alt));
    try DOMErr(err);
}

pub fn inputGetChecked(input: *Input) !bool {
    var checked: bool = false;
    const err = c.dom_html_input_element_get_checked(input, &checked);
    try DOMErr(err);
    return checked;
}
pub fn inputSetChecked(input: *Input, checked: bool) !void {
    const err = c.dom_html_input_element_set_checked(input, checked);
    try DOMErr(err);
}

pub fn inputGetDisabled(input: *Input) !bool {
    var disabled: bool = false;
    const err = c.dom_html_input_element_get_disabled(input, &disabled);
    try DOMErr(err);
    return disabled;
}
pub fn inputSetDisabled(input: *Input, disabled: bool) !void {
    const err = c.dom_html_input_element_set_disabled(input, disabled);
    try DOMErr(err);
}

pub fn inputGetMaxLength(input: *Input) !i32 {
    var max_length: i32 = 0;
    const err = c.dom_html_input_element_get_max_length(input, &max_length);
    try DOMErr(err);
    return max_length;
}
pub fn inputSetMaxLength(input: *Input, max_length: i32) !void {
    if (max_length < 0) return error.NegativeValueNotAllowed;
    const err = c.dom_html_input_element_set_max_length(input, @intCast(max_length));
    try DOMErr(err);
}

pub fn inputGetName(input: *Input) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_input_element_get_name(input, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn inputSetName(input: *Input, name: []const u8) !void {
    const err = c.dom_html_input_element_set_name(input, try strFromData(name));
    try DOMErr(err);
}
pub fn inputGetReadOnly(input: *Input) !bool {
    var read_only: bool = false;
    const err = c.dom_html_input_element_get_read_only(input, &read_only);
    try DOMErr(err);
    return read_only;
}
pub fn inputSetReadOnly(input: *Input, read_only: bool) !void {
    const err = c.dom_html_input_element_set_read_only(input, read_only);
    try DOMErr(err);
}
pub fn inputGetSize(input: *Input) !u32 {
    var size: u32 = 0;
    const err = c.dom_html_input_element_get_size(input, &size);
    try DOMErr(err);
    if (size == ulongNegativeOne) return 20; // 20
    return size;
}
pub fn inputSetSize(input: *Input, size: i32) !void {
    if (size == 0) return error.ZeroNotAllowed;
    const new_size = if (size < 0) 20 else size;
    const err = c.dom_html_input_element_set_size(input, @intCast(new_size));
    try DOMErr(err);
}

pub fn inputGetSrc(input: *Input) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_input_element_get_src(input, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
// url should already be stitched!
pub fn inputSetSrc(input: *Input, src: []const u8) !void {
    const err = c.dom_html_input_element_set_src(input, try strFromData(src));
    try DOMErr(err);
}

pub fn inputGetType(input: *Input) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_input_element_get_type(input, &s_);
    try DOMErr(err);
    const s = s_ orelse return "text";
    return strToData(s);
}
pub fn inputSetType(input: *Input, type_: []const u8) !void {
    // @speed sort values by usage frequency/length
    const possible_values = [_][]const u8{ "text", "search", "tel", "url", "email", "password", "date", "month", "week", "time", "datetime-local", "number", "range", "color", "checkbox", "radio", "file", "hidden", "image", "button", "submit", "reset" };
    var found = false;
    for (possible_values) |item| {
        if (std.mem.eql(u8, type_, item)) {
            found = true;
            break;
        }
    }
    const new_type = if (found) type_ else "text";
    try elementSetAttribute(@ptrCast(@alignCast(input)), "type", new_type);
}

pub fn inputGetValue(input: *Input) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_input_element_get_value(input, &s_);
    try DOMErr(err);
    const s = s_ orelse return "";
    return strToData(s);
}
pub fn inputSetValue(input: *Input, value: []const u8) !void {
    const err = c.dom_html_input_element_set_value(input, try strFromData(value));
    try DOMErr(err);
}

pub fn buttonGetType(button: *Button) ![]const u8 {
    var s_: ?*String = null;
    const err = c.dom_html_button_element_get_type(button, &s_);
    try DOMErr(err);
    const s = s_ orelse return "button";
    return strToData(s);
}

pub fn scriptGetProcessed(script: *Script) !bool {
    var processed: bool = false;
    const err = c.dom_html_script_element_get_processed(script, &processed);
    try DOMErr(err);
    return processed;
}

pub fn scriptSetProcessed(script: *Script, processed: bool) !void {
    const err = c.dom_html_script_element_set_processed(script, processed);
    try DOMErr(err);
}
