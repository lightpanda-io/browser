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
});

const mimalloc = @import("mimalloc");

const Callback = @import("jsruntime").Callback;

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
    undef = c.DOM_HTML_ELEMENT_TYPE__UNKNOWN,

    pub fn all() []Tag {
        comptime {
            const info = @typeInfo(Tag).Enum;
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
    var evt: ?*Event = undefined;
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
    var s: ?*String = undefined;
    const err = c._dom_event_get_type(evt, &s);
    try DOMErr(err);

    // if the event type is null, return a empty string.
    if (s == null) return "";

    return strToData(s.?);
}

pub fn eventTarget(evt: *Event) !?*EventTarget {
    var et: ?*EventTarget = undefined;
    const err = c._dom_event_get_target(evt, &et);
    try DOMErr(err);
    return et;
}

pub fn eventCurrentTarget(evt: *Event) !?*EventTarget {
    var et: ?*EventTarget = undefined;
    const err = c._dom_event_get_current_target(evt, &et);
    try DOMErr(err);
    return et;
}

pub fn eventPhase(evt: *Event) !u8 {
    var phase: c.dom_event_flow_phase = undefined;
    const err = c._dom_event_get_event_phase(evt, &phase);
    try DOMErr(err);
    return @as(u8, @intCast(phase));
}

pub fn eventBubbles(evt: *Event) !bool {
    var res: bool = undefined;
    const err = c._dom_event_get_bubbles(evt, &res);
    try DOMErr(err);
    return res;
}

pub fn eventCancelable(evt: *Event) !bool {
    var res: bool = undefined;
    const err = c._dom_event_get_cancelable(evt, &res);
    try DOMErr(err);
    return res;
}

pub fn eventDefaultPrevented(evt: *Event) !bool {
    var res: bool = undefined;
    const err = c._dom_event_is_default_prevented(evt, &res);
    try DOMErr(err);
    return res;
}

pub fn eventIsTrusted(evt: *Event) !bool {
    var res: bool = undefined;
    const err = c._dom_event_get_is_trusted(evt, &res);
    try DOMErr(err);
    return res;
}

pub fn eventTimestamp(evt: *Event) !u32 {
    var ts: c_uint = undefined;
    const err = c._dom_event_get_timestamp(evt, &ts);
    try DOMErr(err);
    return @as(u32, @intCast(ts));
}

pub fn eventStopPropagation(evt: *Event) !void {
    const err = c._dom_event_stop_propagation(evt);
    try DOMErr(err);
}

pub fn eventStopImmediatePropagation(evt: *Event) !void {
    const err = c._dom_event_stop_immediate_propagation(evt);
    try DOMErr(err);
}

pub fn eventPreventDefault(evt: *Event) !void {
    const err = c._dom_event_prevent_default(evt);
    try DOMErr(err);
}

pub fn eventGetInternalType(evt: *Event) !EventType {
    var res: u32 = undefined;
    const err = c._dom_event_get_internal_type(evt, &res);
    try DOMErr(err);
    return @enumFromInt(res);
}

pub fn eventSetInternalType(evt: *Event, internal_type: EventType) !void {
    const err = c._dom_event_set_internal_type(evt, @intFromEnum(internal_type));
    try DOMErr(err);
}

pub const EventType = enum(u8) {
    event = 0,
    progress_event = 1,
};

pub const MutationEvent = c.dom_mutation_event;

pub fn eventToMutationEvent(evt: *Event) *MutationEvent {
    return @as(*MutationEvent, @ptrCast(evt));
}

pub fn mutationEventAttributeName(evt: *MutationEvent) ![]const u8 {
    var s: ?*String = undefined;
    const err = c._dom_mutation_event_get_attr_name(evt, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn mutationEventPrevValue(evt: *MutationEvent) !?[]const u8 {
    var s: ?*String = undefined;
    const err = c._dom_mutation_event_get_prev_value(evt, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn mutationEventRelatedNode(evt: *MutationEvent) !?*Node {
    var n: NodeExternal = undefined;
    const err = c._dom_mutation_event_get_related_node(evt, &n);
    try DOMErr(err);
    if (n == null) return null;
    return @as(*Node, @ptrCast(n));
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
    return @as(*Node, @ptrCast(et));
}

fn eventTargetVtable(et: *EventTarget) c.dom_event_target_vtable {
    // retrieve the vtable
    const vtable = et.*.vtable.?;
    // align correctly the vtable
    const vtable_aligned: *align(@alignOf([*c]c.dom_event_target_vtable)) const anyopaque = @alignCast(vtable);
    // convert the vtable to it's actual type and return it
    return @as([*c]const c.dom_event_target_vtable, @ptrCast(vtable_aligned)).*;
}

pub inline fn toEventTarget(comptime T: type, v: *T) *EventTarget {
    if (comptime eventTargetTBaseFieldName(T)) |field| {
        const et_aligned: *align(@alignOf(EventTarget)) EventTargetTBase = @alignCast(&@field(v, field));
        return @as(*EventTarget, @ptrCast(et_aligned));
    }

    const et_aligned: *align(@alignOf(EventTarget)) T = @alignCast(v);
    return @as(*EventTarget, @ptrCast(et_aligned));
}

pub fn eventTargetHasListener(
    et: *EventTarget,
    typ: []const u8,
    capture: bool,
    cbk_id: usize,
) !?*EventListener {
    const str = try strFromData(typ);

    var current: ?*EventListenerEntry = null;
    var next: ?*EventListenerEntry = undefined;
    var lst: ?*EventListener = undefined;

    // iterate over the EventTarget's listeners
    while (true) {
        const err = eventTargetVtable(et).iter_event_listener.?(
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
            const ehd = EventHandlerDataInternal.fromListener(listener);
            if (ehd) |d| {
                if (cbk_id == d.data.cbk.id()) {
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

// EventHandlerFunc is a zig function called when the event is dispatched to a
// listener.
// The EventHandlerFunc is responsible to call the callback included into the
// EventHandlerData.
pub const EventHandlerFunc = *const fn (event: ?*Event, data: EventHandlerData) void;

// EventHandler implements the function exposed in C and called by libdom.
// It retrieves the EventHandlerInternalData and call the EventHandlerFunc with
// the EventHandlerData in parameter.
const EventHandler = struct {
    fn handle(event: ?*Event, data: ?*anyopaque) callconv(.C) void {
        if (data) |d| {
            const ehd = EventHandlerDataInternal.get(d);
            ehd.handler(event, ehd.data);

            // NOTE: we can not call func.deinit here
            // b/c the handler can be called several times
            // either on this dispatch event or in anoter one
        }
    }
}.handle;

// EventHandlerData contains a JS callback and the data associated to the
// handler.
// If given, deinitFunc is called with the data pointer to allow the creator to
// clean memory.
// The callback is deinit by EventHandlerDataInternal. It must NOT be deinit
// into deinitFunc.
pub const EventHandlerData = struct {
    cbk: Callback,
    data: ?*anyopaque = null,
    // deinitFunc implements the data deinitialization.
    deinitFunc: ?DeinitFunc = null,

    pub const DeinitFunc = *const fn (data: ?*anyopaque, alloc: std.mem.Allocator) void;
};

// EventHandlerDataInternal groups the EventHandlerFunc and the EventHandlerData.
const EventHandlerDataInternal = struct {
    data: EventHandlerData,
    handler: EventHandlerFunc,

    fn init(alloc: std.mem.Allocator, handler: EventHandlerFunc, data: EventHandlerData) !*EventHandlerDataInternal {
        const ptr = try alloc.create(EventHandlerDataInternal);
        ptr.* = .{
            .data = data,
            .handler = handler,
        };
        return ptr;
    }

    fn deinit(self: *EventHandlerDataInternal, alloc: std.mem.Allocator) void {
        if (self.data.deinitFunc) |d| d(self.data.data, alloc);
        self.data.cbk.deinit(alloc);
        alloc.destroy(self);
    }

    fn get(data: *anyopaque) *EventHandlerDataInternal {
        const ptr: *align(@alignOf(*EventHandlerDataInternal)) anyopaque = @alignCast(data);
        return @as(*EventHandlerDataInternal, @ptrCast(ptr));
    }

    // retrieve a EventHandlerDataInternal from a listener.
    fn fromListener(lst: *EventListener) ?*EventHandlerDataInternal {
        const data = eventListenerGetData(lst);
        // free cbk allocation made on eventTargetAddEventListener
        if (data == null) return null;

        return get(data.?);
    }
};

pub fn eventTargetAddEventListener(
    et: *EventTarget,
    alloc: std.mem.Allocator,
    typ: []const u8,
    handlerFunc: EventHandlerFunc,
    data: EventHandlerData,
    capture: bool,
) !void {
    // this allocation will be removed either on
    // eventTargetRemoveEventListener or eventTargetRemoveAllEventListeners
    const ehd = try EventHandlerDataInternal.init(alloc, handlerFunc, data);
    errdefer ehd.deinit(alloc);

    // When a function is used as an event handler, its this parameter is bound
    // to the DOM element on which the listener is placed.
    // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/this#this_in_dom_event_handlers
    try ehd.data.cbk.setThisArg(et);

    const ctx = @as(*anyopaque, @ptrCast(ehd));
    var listener: ?*EventListener = undefined;
    const errLst = c.dom_event_listener_create(EventHandler, ctx, &listener);
    try DOMErr(errLst);
    defer c.dom_event_listener_unref(listener);

    const s = try strFromData(typ);
    const err = eventTargetVtable(et).add_event_listener.?(et, s, listener, capture);
    try DOMErr(err);
}

pub fn eventTargetRemoveEventListener(
    et: *EventTarget,
    alloc: std.mem.Allocator,
    typ: []const u8,
    lst: *EventListener,
    capture: bool,
) !void {
    // free data allocation made on eventTargetAddEventListener
    const ehd = EventHandlerDataInternal.fromListener(lst);
    if (ehd) |d| d.deinit(alloc);

    const s = try strFromData(typ);
    const err = eventTargetVtable(et).remove_event_listener.?(et, s, lst, capture);
    try DOMErr(err);
}

pub fn eventTargetRemoveAllEventListeners(
    et: *EventTarget,
    alloc: std.mem.Allocator,
) !void {
    var next: ?*EventListenerEntry = undefined;
    var lst: ?*EventListener = undefined;

    // iterate over the EventTarget's listeners
    while (true) {
        const errIter = eventTargetVtable(et).iter_event_listener.?(
            et,
            null,
            false,
            null,
            &next,
            &lst,
        );
        try DOMErr(errIter);

        if (lst) |listener| {
            defer c.dom_event_listener_unref(listener);

            const ehd = EventHandlerDataInternal.fromListener(listener);
            if (ehd) |d| d.deinit(alloc);

            const err = eventTargetVtable(et).remove_event_listener.?(
                et,
                null,
                lst,
                false,
            );
            try DOMErr(err);
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

pub fn eventTargetTBaseFieldName(comptime T: type) ?[]const u8 {
    std.debug.assert(@inComptime());
    switch (@typeInfo(T)) {
        .Struct => |ti| {
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

    vtable: ?*const c.struct_dom_event_target_vtable = &c.struct_dom_event_target_vtable{
        .dispatch_event = dispatch_event,
        .remove_event_listener = remove_event_listener,
        .add_event_listener = add_event_listener,
        .iter_event_listener = iter_event_listener,
    },
    eti: c.dom_event_target_internal = c.dom_event_target_internal{ .listeners = null },

    pub fn add_event_listener(et: [*c]c.dom_event_target, t: [*c]c.dom_string, l: ?*c.struct_dom_event_listener, capture: bool) callconv(.C) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        return c._dom_event_target_add_event_listener(&self.eti, t, l, capture);
    }

    pub fn dispatch_event(et: [*c]c.dom_event_target, evt: ?*c.struct_dom_event, res: [*c]bool) callconv(.C) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        // Set the event target to the target dispatched.
        const e = c._dom_event_set_target(evt, et);
        if (e != c.DOM_NO_ERR) {
            return e;
        }
        return c._dom_event_target_dispatch(et, &self.eti, evt, c.DOM_AT_TARGET, res);
    }

    pub fn remove_event_listener(et: [*c]c.dom_event_target, t: [*c]c.dom_string, l: ?*c.struct_dom_event_listener, capture: bool) callconv(.C) c.dom_exception {
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
    ) callconv(.C) c.dom_exception {
        const self = @as(*Self, @ptrCast(et));
        return c._dom_event_target_iter_event_listener(self.eti, t, capture, cur, next, l);
    }
};

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

pub fn nodeGetChildNodes(node: *Node) !*NodeList {
    var nlist: ?*NodeList = undefined;
    const err = nodeVtable(node).dom_node_get_child_nodes.?(node, &nlist);
    try DOMErr(err);
    return nlist.?;
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

pub fn nodeGetNamespace(node: *Node) !?[]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_get_namespace.?(node, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
}

pub fn nodeGetPrefix(node: *Node) !?[]const u8 {
    var s: ?*String = undefined;
    const err = nodeVtable(node).dom_node_get_prefix.?(node, &s);
    try DOMErr(err);
    if (s == null) return null;
    return strToData(s.?);
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

// ProcessingInstruction
pub const ProcessingInstruction = c.dom_processing_instruction;

// processingInstructionToNode is an helper to convert an ProcessingInstruction to a node.
pub inline fn processingInstructionToNode(pi: *ProcessingInstruction) *Node {
    return @as(*Node, @ptrCast(pi));
}

pub fn processInstructionCopy(pi: *ProcessingInstruction) !*ProcessingInstruction {
    var res: ?*Node = undefined;
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
    var s: ?*String = undefined;
    const err = attributeVtable(a).dom_attr_get_name.?(a, &s);
    try DOMErr(err);

    return strToData(s.?);
}

pub fn attributeGetValue(a: *Attribute) !?[]const u8 {
    var s: ?*String = undefined;
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
    var elt: ?*Element = undefined;
    const err = attributeVtable(a).dom_attr_get_owner_element.?(a, &elt);
    try DOMErr(err);
    if (elt == null) return null;

    return elt.?;
}

// attributeToNode is an helper to convert an attribute to a node.
pub inline fn attributeToNode(a: *Attribute) *Node {
    return @as(*Node, @ptrCast(a));
}

// Element
pub const Element = c.dom_element;

fn elementVtable(elem: *Element) c.dom_element_vtable {
    return getVtable(c.dom_element_vtable, Element, elem);
}

pub fn elementGetAttribute(elem: *Element, name: []const u8) !?[]const u8 {
    var s: ?*String = undefined;
    const err = elementVtable(elem).dom_element_get_attribute.?(elem, try strFromData(name), &s);
    try DOMErr(err);
    if (s == null) return null;

    return strToData(s.?);
}

pub fn elementGetAttributeNS(elem: *Element, ns: []const u8, name: []const u8) !?[]const u8 {
    var s: ?*String = undefined;
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
    const err = elementVtable(elem).dom_element_set_attribute.?(
        elem,
        try strFromData(qname),
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
    const err = elementVtable(elem).dom_element_set_attribute_ns.?(
        elem,
        try strFromData(ns),
        try strFromData(qname),
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

pub fn elementGetAttributeNode(elem: *Element, name: []const u8) !?*Attribute {
    var a: ?*Attribute = undefined;
    const err = elementVtable(elem).dom_element_get_attribute_node.?(elem, try strFromData(name), &a);
    try DOMErr(err);
    return a;
}

pub fn elementGetAttributeNodeNS(elem: *Element, ns: []const u8, name: []const u8) !?*Attribute {
    var a: ?*Attribute = undefined;
    const err = elementVtable(elem).dom_element_get_attribute_node_ns.?(
        elem,
        try strFromData(ns),
        try strFromData(name),
        &a,
    );
    try DOMErr(err);
    return a;
}

pub fn elementSetAttributeNode(elem: *Element, attr: *Attribute) !?*Attribute {
    var a: ?*Attribute = undefined;
    const err = elementVtable(elem).dom_element_set_attribute_node.?(elem, attr, &a);
    try DOMErr(err);
    return a;
}

pub fn elementSetAttributeNodeNS(elem: *Element, attr: *Attribute) !?*Attribute {
    var a: ?*Attribute = undefined;
    const err = elementVtable(elem).dom_element_set_attribute_node_ns.?(elem, attr, &a);
    try DOMErr(err);
    return a;
}

pub fn elementRemoveAttributeNode(elem: *Element, attr: *Attribute) !*Attribute {
    var a: ?*Attribute = undefined;
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
    return @as(*Node, @ptrCast(e));
}

// TokenList
pub const TokenList = c.dom_tokenlist;

pub fn tokenListCreate(elt: *Element, attr: []const u8) !*TokenList {
    var list: ?*TokenList = undefined;
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
    var res: ?*String = undefined;
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
    var res: ?*String = undefined;
    const err = c.dom_tokenlist_get_value(l, &res);
    try DOMErr(err);
    if (res == null) return null;
    return strToData(res.?);
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

// HTMLScriptElement

// scriptToElt is an helper to convert an script to an element.
pub inline fn scriptToElt(s: *Script) *Element {
    return @as(*Element, @ptrCast(s));
}

// HTMLAnchorElement

// anchorToNode is an helper to convert an anchor to a node.
pub inline fn anchorToNode(a: *Anchor) *Node {
    return @as(*Node, @ptrCast(a));
}

pub fn anchorGetTarget(a: *Anchor) ![]const u8 {
    var res: ?*String = undefined;
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
    var res: ?*String = undefined;
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
    var res: ?*String = undefined;
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
    var res: ?*String = undefined;
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
    var res: ?*String = undefined;
    const err = c.dom_html_anchor_element_get_rel(a, &res);
    try DOMErr(err);
    if (res == null) return "";
    return strToData(res.?);
}

pub fn anchorSetRel(a: *Anchor, rel: []const u8) !void {
    const err = c.dom_html_anchor_element_set_rel(a, try strFromData(rel));
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

pub inline fn documentFragmentToNode(doc: *DocumentFragment) *Node {
    return @as(*Node, @ptrCast(doc));
}

pub fn documentFragmentBodyChildren(doc: *DocumentFragment) !?*NodeList {
    const node = documentFragmentToNode(doc);
    const html = try nodeFirstChild(node) orelse return null;
    // TODO unref
    const head = try nodeFirstChild(html) orelse return null;
    // TODO unref
    const body = try nodeNextSibling(head) orelse return null;
    // TODO unref

    return try nodeGetChildNodes(body);
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

pub inline fn domImplementationCreateHTMLDocument(title: ?[]const u8) !*DocumentHTML {
    const doc_html = try documentCreateDocument(title);
    const doc = documentHTMLToDocument(doc_html);

    // add hierarchy: html, head, body.
    const html = try documentCreateElement(doc, "html");
    _ = try nodeAppendChild(documentToNode(doc), elementToNode(html));

    const head = try documentCreateElement(doc, "head");
    _ = try nodeAppendChild(elementToNode(html), elementToNode(head));

    if (title) |t| {
        try documentHTMLSetTitle(doc_html, t);
        const htitle = try documentCreateElement(doc, "title");
        const txt = try documentCreateTextNode(doc, t);
        _ = try nodeAppendChild(elementToNode(htitle), @as(*Node, @ptrCast(txt)));
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
    return @as(*Node, @ptrCast(doc));
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
pub inline fn documentGetDocumentElement(doc: *Document) !?*Element {
    var elem: ?*Element = undefined;
    const err = documentVtable(doc).dom_document_get_document_element.?(doc, &elem);
    try DOMErr(err);
    if (elem == null) return null;
    return elem.?;
}

pub inline fn documentGetDocumentURI(doc: *Document) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentVtable(doc).dom_document_get_uri.?(doc, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub fn documentSetDocumentURI(doc: *Document, uri: []const u8) !void {
    const err = documentVtable(doc).dom_document_set_uri.?(doc, try strFromData(uri));
    try DOMErr(err);
}

pub inline fn documentGetInputEncoding(doc: *Document) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentVtable(doc).dom_document_get_input_encoding.?(doc, &s);
    try DOMErr(err);
    return strToData(s.?);
}

pub inline fn documentSetInputEncoding(doc: *Document, enc: []const u8) !void {
    const err = documentVtable(doc).dom_document_set_input_encoding.?(doc, try strFromData(enc));
    try DOMErr(err);
}

pub inline fn documentCreateDocument(title: ?[]const u8) !*DocumentHTML {
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
    const doc_html = @as(*DocumentHTML, @ptrCast(doc.?));
    if (title) |t| try documentHTMLSetTitle(doc_html, t);
    return doc_html;
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

pub inline fn documentCreateComment(doc: *Document, s: []const u8) !*Comment {
    var com: ?*Comment = undefined;
    const err = documentVtable(doc).dom_document_create_comment.?(doc, try strFromData(s), &com);
    try DOMErr(err);
    return com.?;
}

pub inline fn documentCreateProcessingInstruction(doc: *Document, target: []const u8, data: []const u8) !*ProcessingInstruction {
    var pi: ?*ProcessingInstruction = undefined;
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
    return @as(*Node, @ptrCast(res));
}

pub inline fn documentAdoptNode(doc: *Document, node: *Node) !*Node {
    var res: NodeExternal = undefined;
    const nodeext = toNodeExternal(Node, node);
    const err = documentVtable(doc).dom_document_adopt_node.?(doc, nodeext, &res);
    try DOMErr(err);
    return @as(*Node, @ptrCast(res));
}

pub inline fn documentCreateAttribute(doc: *Document, name: []const u8) !*Attribute {
    var attr: ?*Attribute = undefined;
    const err = documentVtable(doc).dom_document_create_attribute.?(doc, try strFromData(name), &attr);
    try DOMErr(err);
    return attr.?;
}

pub inline fn documentCreateAttributeNS(doc: *Document, ns: []const u8, qname: []const u8) !*Attribute {
    var attr: ?*Attribute = undefined;
    const err = documentVtable(doc).dom_document_create_attribute_ns.?(
        doc,
        try strFromData(ns),
        try strFromData(qname),
        &attr,
    );
    try DOMErr(err);
    return attr.?;
}

// DocumentHTML
pub const DocumentHTML = c.dom_html_document;

// documentHTMLToNode is an helper to convert a documentHTML to an node.
pub inline fn documentHTMLToNode(doc: *DocumentHTML) *Node {
    return @as(*Node, @ptrCast(doc));
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

// documentHTMLParseFromStr parses the given HTML string.
// The caller is responsible for closing the document.
pub fn documentHTMLParseFromStr(str: []const u8) !*DocumentHTML {
    var fbs = std.io.fixedBufferStream(str);
    return try documentHTMLParse(fbs.reader(), "UTF-8");
}

pub fn documentHTMLParse(reader: anytype, enc: ?[:0]const u8) !*DocumentHTML {
    var parser: ?*c.dom_hubbub_parser = undefined;
    var doc: ?*c.dom_document = undefined;
    var err: c.hubbub_error = undefined;
    var params = parseParams(enc);

    err = c.dom_hubbub_parser_create(&params, &parser, &doc);
    try parserErr(err);
    defer c.dom_hubbub_parser_destroy(parser);

    try parseData(parser.?, reader);

    return @as(*DocumentHTML, @ptrCast(doc.?));
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
    var body: ?*ElementHTML = undefined;
    const err = documentHTMLVtable(doc_html).get_body.?(doc_html, &body);
    try DOMErr(err);
    if (body == null) return null;
    return @as(*Body, @ptrCast(body.?));
}

pub inline fn documentHTMLSetBody(doc_html: *DocumentHTML, elt: ?*ElementHTML) !void {
    const err = documentHTMLVtable(doc_html).set_body.?(doc_html, elt);
    try DOMErr(err);
}

pub inline fn documentHTMLGetDomain(doc: *DocumentHTML) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentHTMLVtable(doc).get_domain.?(doc, &s);
    try DOMErr(err);
    if (s == null) return "";
    return strToData(s.?);
}

pub inline fn documentHTMLGetReferrer(doc: *DocumentHTML) ![]const u8 {
    var s: ?*String = undefined;
    const err = documentHTMLVtable(doc).get_referrer.?(doc, &s);
    try DOMErr(err);
    if (s == null) return "";
    return strToData(s.?);
}

pub inline fn documentHTMLGetTitle(doc: *DocumentHTML) ![]const u8 {
    var s: ?*String = undefined;
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
    if (script != null) s = @ptrCast(script.?);
    const err = documentHTMLVtable(doc).set_current_script.?(doc, s);
    try DOMErr(err);
}

pub fn documentHTMLGetCurrentScript(doc: *DocumentHTML) !?*Script {
    var elem: ?*ElementHTML = undefined;
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
    var l: ?*anyopaque = undefined;
    const err = documentHTMLVtable(doc).get_location.?(doc, &l);
    try DOMErr(err);

    if (l == null) return null;

    const ptr: *align(@alignOf(*T)) anyopaque = @alignCast(l.?);
    return @as(*T, @ptrCast(ptr));
}
