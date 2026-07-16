// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Window = @import("Window.zig");
const URL = @import("../URL.zig");
const idna = @import("../../sys/idna.zig");
const public_suffix_list = @import("../../data/public_suffix_list.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Location = @import("Location.zig");
const Parser = @import("../parser/Parser.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");
const StyleSheetList = @import("css/StyleSheetList.zig");
const FontFaceSet = @import("css/FontFaceSet.zig");
const Selection = @import("Selection.zig");
const XPathResult = @import("XPathResult.zig");
const XPathExpression = @import("XPathExpression.zig");

pub const XMLDocument = @import("XMLDocument.zig");
pub const HTMLDocument = @import("HTMLDocument.zig");

const log = lp.log;
const String = lp.String;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Document = @This();

_type: Type,
_proto: *Node,
_frame: ?*Frame = null,
_url: ?[:0]const u8 = null, // URL for documents created via DOMImplementation (about:blank)
// content type override for documents created via DOMImplementation.createDocument
_content_type: ?[]const u8 = null,
// encoding override: documents synthesized by script (createHTMLDocument,
// createDocument) are UTF-8 regardless of the frame's encoding
_charset: ?[]const u8 = null,
_ready_state: ReadyState = .loading,
_current_script: ?*Element.Html.Script = null,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .empty,
// Track IDs that were removed from the map - they might have duplicates in the tree
_removed_ids: std.StringHashMapUnmanaged(void) = .empty,
_active_element: ?*Element = null,
_style_sheets: ?*StyleSheetList = null,
_implementation: ?*DOMImplementation = null,
_fonts: ?*FontFaceSet = null,
_write_insertion_point: ?*Node = null,
_script_created_parser: ?Parser.Streaming = null,
_close_requested: bool = false,
_adopted_style_sheets: ?js.Object.Global = null,
_selection: Selection = .{ ._rc = .init(1) },
// Ordered stack of currently-showing popovers
_open_popovers: std.ArrayList(*Element) = .empty,

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#throw-on-dynamic-markup-insertion-counter
// Incremented during custom element reactions when parsing. When > 0,
// document.open/close/write/writeln must throw InvalidStateError.
_throw_on_dynamic_markup_insertion_counter: u32 = 0,

_on_selectionchange: ?js.Function.Global = null,

pub fn getOnSelectionChange(self: *Document) ?js.Function.Global {
    return self._on_selectionchange;
}

pub fn setOnSelectionChange(self: *Document, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_selectionchange = try listen.persistWithThis(self);
    } else {
        self._on_selectionchange = null;
    }
}

// Stored in the frame's attribute-listener map (like element and ShadowRoot
// property handlers), which the dispatch propagation path consults for any
// event target.
pub fn getOnClick(self: *Document, frame: *Frame) ?js.Function.Global {
    return (self._frame orelse frame)._event_target_attr_listeners.get(.{ .target = self.asEventTarget(), .handler = .onclick });
}

pub fn setOnClick(self: *Document, setter: ?Window.FunctionSetter, frame: *Frame) !void {
    const owner = self._frame orelse frame;
    if (Window.getFunctionFromSetter(setter)) |cb| {
        try owner._event_target_attr_listeners.put(owner.arena, .{ .target = self.asEventTarget(), .handler = .onclick }, cb);
    } else {
        _ = owner._event_target_attr_listeners.remove(.{ .target = self.asEventTarget(), .handler = .onclick });
    }
}

pub const Type = union(enum) {
    generic,
    html: *HTMLDocument,
    xml: *XMLDocument,
};

pub fn is(self: *Document, comptime T: type) ?*T {
    switch (self._type) {
        .html => |html| {
            if (T == HTMLDocument) {
                return html;
            }
        },
        .xml => |xml| {
            if (T == XMLDocument) {
                return xml;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Document, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Document) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *Document) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getURL(self: *const Document, frame: *const Frame) [:0]const u8 {
    return self._url orelse (self._frame orelse frame).url;
}

pub fn getLocation(self: *const Document) ?*Location {
    if (self._type != .html) return null;
    const doc_frame = self._frame orelse return null;
    return doc_frame.window._location;
}

pub fn setLocation(self: *Document, url: [:0]const u8) !void {
    if (self._type != .html) return;
    const frame = self._frame orelse return;
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = frame });
}

// Approximation of quirks mode: an HTML document without a doctype is in quirks mode.
pub fn isQuirksMode(self: *const Document) bool {
    if (self._type != .html) {
        return false;
    }
    var it = self._proto.childrenIterator();
    while (it.next()) |child| {
        if (child._type == .document_type) {
            return false;
        }
    }
    return true;
}

pub fn getCompatMode(self: *const Document) []const u8 {
    return if (self.isQuirksMode()) "BackCompat" else "CSS1Compat";
}

pub fn getCharset(self: *const Document) []const u8 {
    if (self._charset) |charset| {
        return charset;
    }
    const doc_frame = self._frame orelse return "UTF-8";
    return doc_frame.charset;
}

pub fn getContentType(self: *const Document) []const u8 {
    if (self._content_type) |content_type| {
        return content_type;
    }
    return switch (self._type) {
        .html => "text/html",
        .xml => "application/xml",
        .generic => "application/xml",
    };
}

pub fn getDomain(self: *const Document, frame: *const Frame) []const u8 {
    const doc_frame = self._frame orelse frame;

    // When document.domain has been set, the effective domain is encoded in
    // the origin key with a leading '!' marker. The key is a "!scheme://host"
    // serialization with the port already dropped, so the host *is* the
    // effective domain.
    const key = doc_frame.js.origin.key;
    if (key.len != 0 and key[0] == '!') {
        return URL.getHost(key[1..]);
    }

    // Derive from the origin, not the URL: an about:blank child inherits the
    // parent origin while keeping url == "about:blank". Opaque origin => "".
    const origin = doc_frame.origin orelse return "";
    return URL.getOriginHostname(origin);
}

pub fn setDomain(self: *Document, value: []const u8) !void {
    // e.g. (new Document().domain = '')
    const doc_frame = self._frame orelse return error.SecurityError;
    const origin = doc_frame.origin orelse return error.SecurityError;

    const arena = doc_frame.local_arena;
    const requested = if (idna.needsAscii(value)) try idna.toAscii(arena, value) else value;

    // Validate against the current effective domain. Once relaxed,
    // document.domain can only broaden further.
    const base = self.getDomain(doc_frame);
    if (isRelaxableTo(base, requested) == false) {
        return error.SecurityError;
    }

    // When the domain is explicitly set, it only matches other explicitly set
    // domains. We do this by prepending a '!' to the origin, so that it can
    // only ever match another explicitly set domain.
    // The scheme is preserved (http and https must never collide) and the
    // port is dropped, per spec.
    const scheme_end = (std.mem.indexOf(u8, origin, "://") orelse return error.SecurityError) + 3;
    const key = try std.mem.concat(arena, u8, &.{ "!", origin[0..scheme_end], requested });
    try doc_frame.js.setOrigin(key);
}

pub fn getCookie(_: *Document, frame: *Frame) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try frame._session.cookie_jar.forRequest(frame.url, buf.writer(frame.local_arena), .{
        .is_http = false,
        .is_navigation = true,
    });
    return buf.items;
}

pub fn setCookie(_: *Document, cookie_str: []const u8, frame: *Frame) ![]const u8 {
    // we use the cookie jar's allocator to parse the cookie because it
    // outlives the frame's arena.
    const Cookie = @import("storage/Cookie.zig");
    const c = Cookie.parse(frame._session.cookie_jar.allocator, frame.url, cookie_str) catch {
        // Invalid cookies should be silently ignored, not throw errors
        return "";
    };
    if (c.http_only) {
        c.deinit();
        return ""; // HttpOnly cookies cannot be set from JS
    }
    try frame._session.cookie_jar.add(c, std.time.timestamp(), false);
    return cookie_str;
}

// Returns true if the requested domain is valid for the given host
fn isRelaxableTo(host: []const u8, requested: []const u8) bool {
    if (requested.len == 0) {
        return false;
    }

    // Pure opt-in: relaxing to your own host is always allowed (and it's the
    // only valid value for IPs)
    if (std.mem.eql(u8, host, requested)) {
        return true;
    }

    // request must be a subset of host, so it must be smaller
    if (host.len <= requested.len) {
        return false;
    }

    if (host[host.len - requested.len - 1] != '.') {
        return false;
    }

    if (std.mem.endsWith(u8, host, requested) == false) {
        return false;
    }

    // it can't be a bare TLD, "com"
    if (std.mem.indexOfScalar(u8, requested, '.') == null) {
        return false;
    }

    // and it can't be a public suffix (e.g. "gov.uk")
    return public_suffix_list.lookup(requested) == false;
}

const CreateElementOptions = struct {
    is: ?[]const u8 = null,
};

pub fn createElement(self: *Document, name: []const u8, options_: ?CreateElementOptions, frame: *Frame) !*Element {
    try validateElementName(name);
    const ns: Element.Namespace, const normalized_name = blk: {
        if (self._type == .html) {
            break :blk .{ .html, std.ascii.lowerString(&frame.buf, name) };
        }
        // Generic and XML documents create elements with null namespace
        break :blk .{ .null, name };
    };
    // HTML documents are case-insensitive - lowercase the tag name

    const node = try Frame.node_factory.createElementNS(frame, ns, normalized_name, null);
    const element = node.as(Element);

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }

    const options = options_ orelse return element;
    if (options.is) |is_value| {
        try element.setAttribute(comptime .wrap("is"), .wrap(is_value), frame);
        try Element.Html.Custom.checkAndAttachBuiltIn(element, frame);
    }

    return element;
}

pub fn createElementNS(self: *Document, namespace: ?[]const u8, name: []const u8, frame: *Frame) !*Element {
    _ = try validateAndExtract(namespace, name, .element);
    const ns = Element.Namespace.parse(namespace);
    // Per spec, createElementNS does NOT lowercase (unlike createElement).
    const node = try Frame.node_factory.createElementNS(frame, ns, name, null);

    // Store original URI for unknown namespaces so lookupNamespaceURI can return it
    if (ns == .unknown) {
        if (namespace) |uri| {
            const duped = try frame.dupeString(uri);
            try frame._element_namespace_uris.put(frame.arena, node.as(Element), duped);
        }
    }

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node.as(Element);
}

pub fn createAttribute(_: *const Document, name: String.Global, frame: *Frame) !?*Element.Attribute {
    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(Element.Attribute{
        ._proto = undefined,
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn createAttributeNS(_: *const Document, namespace: []const u8, name: String.Global, frame: *Frame) !?*Element.Attribute {
    if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml") == false) {
        log.warn(.not_implemented, "document.createAttributeNS", .{ .namespace = namespace });
    }

    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(Element.Attribute{
        ._proto = undefined,
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn getElementById(self: *Document, id: []const u8, frame: *Frame) ?*Element {
    if (id.len == 0) {
        return null;
    }

    if (self._elements_by_id.get(id)) |element| {
        return element;
    }

    //ID was removed but might have duplicates
    if (self._removed_ids.remove(id)) {
        var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
        while (tw.next()) |el| {
            const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
            if (std.mem.eql(u8, element_id, id)) {
                // we ignore this error to keep getElementById easy to call
                // if it really failed, then we're out of memory and nothing's
                // going to work like it should anyways.
                const owned_id = frame.dupeString(id) catch return null;
                self._elements_by_id.put(frame.arena, owned_id, el) catch return null;
                return el;
            }
        }
    }

    return null;
}

pub fn getElementsByTagName(self: *Document, tag_name: []const u8, frame: *Frame) !Node.GetElementsByTagNameResult {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Document, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Document, class_name: []const u8, frame: *Frame) !collections.NodeLive(.class_name) {
    return self.asNode().getElementsByClassName(class_name, frame);
}

pub fn getElementsByName(self: *Document, name: []const u8, frame: *Frame) !collections.NodeLive(.name) {
    const arena = frame.arena;
    const filter = try arena.dupe(u8, name);
    return collections.NodeLive(.name).init(self.asNode(), filter, frame);
}

pub fn getChildren(self: *Document, frame: *Frame) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, frame);
}

pub fn getDocumentElement(self: *Document) ?*Element {
    var child = self.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element)) |el| {
            return el;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getSelection(self: *Document) *Selection {
    return &self._selection;
}

pub fn querySelector(self: *Document, input: String, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), input.str(), frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn querySelectorAll(self: *Document, input: String, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input.str(), frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn getImplementation(self: *Document, frame: *Frame) !*DOMImplementation {
    if (self._implementation) |impl| return impl;
    const impl = try frame._factory.create(DOMImplementation{ ._document = self });
    self._implementation = impl;
    return impl;
}

pub fn createDocumentFragment(self: *Document, frame: *Frame) !*Node.DocumentFragment {
    const frag = try Node.DocumentFragment.init(frame);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(frag.asNode(), self);
    }
    return frag;
}

pub fn createComment(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createComment(frame, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createTextNode(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createTextNode(frame, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createCDATASection(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = switch (self._type) {
        .html => return error.NotSupported, // cannot create a CDataSection in an HTMLDocument
        .xml => try Frame.node_factory.createCDATASection(frame, data),
        .generic => try Frame.node_factory.createCDATASection(frame, data),
    };
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createProcessingInstruction(self: *Document, target: []const u8, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createProcessingInstruction(frame, target, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

const Range = @import("Range.zig");
pub fn createRange(self: *Document, frame: *Frame) !*Range {
    return Range.initIn(self.asNode(), frame);
}

pub fn createEvent(_: *const Document, event_type: []const u8, frame: *Frame) !*@import("Event.zig") {
    const Event = @import("Event.zig");
    if (event_type.len > 100) {
        return error.NotSupported;
    }
    const normalized = std.ascii.lowerString(&frame.buf, event_type);

    const event: *Event = blk: {
        if (std.mem.eql(u8, normalized, "event") or std.mem.eql(u8, normalized, "events") or std.mem.eql(u8, normalized, "htmlevents") or std.mem.eql(u8, normalized, "svgevents")) {
            break :blk try Event.init("", null, frame._page);
        }

        if (std.mem.eql(u8, normalized, "customevent")) {
            const CustomEvent = @import("event/CustomEvent.zig");
            break :blk (try CustomEvent.init("", null, frame._page)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "keyboardevent")) {
            const KeyboardEvent = @import("event/KeyboardEvent.zig");
            break :blk (try KeyboardEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "inputevent")) {
            const InputEvent = @import("event/InputEvent.zig");
            break :blk (try InputEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "mouseevent") or std.mem.eql(u8, normalized, "mouseevents")) {
            const MouseEvent = @import("event/MouseEvent.zig");
            break :blk (try MouseEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "dragevent")) {
            const DragEvent = @import("event/DragEvent.zig");
            break :blk (try DragEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "messageevent")) {
            const MessageEvent = @import("event/MessageEvent.zig");
            break :blk (try MessageEvent.init("", null, frame._page)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "hashchangeevent")) {
            const HashChangeEvent = @import("event/HashChangeEvent.zig");
            break :blk (try HashChangeEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "uievent") or std.mem.eql(u8, normalized, "uievents")) {
            const UIEvent = @import("event/UIEvent.zig");
            break :blk (try UIEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "focusevent")) {
            const FocusEvent = @import("event/FocusEvent.zig");
            break :blk (try FocusEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "textevent")) {
            const TextEvent = @import("event/TextEvent.zig");
            break :blk (try TextEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "compositionevent")) {
            const CompositionEvent = @import("event/CompositionEvent.zig");
            break :blk (try CompositionEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "beforeunloadevent")) {
            const BeforeUnloadEvent = @import("event/BeforeUnloadEvent.zig");
            break :blk (try BeforeUnloadEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "devicemotionevent")) {
            const DeviceMotionEvent = @import("event/DeviceMotionEvent.zig");
            break :blk (try DeviceMotionEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "deviceorientationevent")) {
            const DeviceOrientationEvent = @import("event/DeviceOrientationEvent.zig");
            break :blk (try DeviceOrientationEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "storageevent")) {
            const StorageEvent = @import("event/StorageEvent.zig");
            break :blk (try StorageEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "touchevent")) {
            const TouchEvent = @import("event/TouchEvent.zig");
            break :blk (try TouchEvent.init("", null, frame)).asEvent();
        }

        return error.NotSupported;
    };

    // createEvent returns an uninitialized event: dispatching it before one
    // of the init*Event calls throws an InvalidStateError.
    event._initialized = false;
    return event;
}

pub fn createTreeWalker(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMTreeWalker.FilterOpts, frame: *Frame) !*DOMTreeWalker {
    return DOMTreeWalker.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn createNodeIterator(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMNodeIterator.FilterOpts, frame: *Frame) !*DOMNodeIterator {
    return DOMNodeIterator.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn evaluate(
    self: *Document,
    expression: []const u8,
    context_node: ?*Node,
    resolver: ?js.Function,
    result_type: ?u16,
    result: ?*XPathResult,
    frame: *Frame,
) !*XPathResult {
    // resolver/result are no-ops in HTML mode (decision #2).
    // Null/missing context_node falls back to the document — matches the
    // polyfill (decision #2). Firefox throws TypeError on a *missing*
    // arg, but the bridge can't distinguish "missing" from "explicit
    // null" here, so polyfill parity wins for the ambiguity.
    _ = resolver;
    _ = result;
    return XPathResult.fromExpression(
        expression,
        context_node orelse self.asNode(),
        result_type orelse XPathResult.ANY_TYPE,
        frame,
    );
}

pub fn createExpression(
    _: *const Document,
    expression: []const u8,
    resolver: ?js.Function,
    frame: *Frame,
) !*XPathExpression {
    _ = resolver;
    return XPathExpression.init(expression, frame);
}

pub fn createNSResolver(_: *const Document, node: *Node) ?*Node {
    return node;
}

fn whatToShow(value_: ?js.Value) !u32 {
    const value = value_ orelse return 4294967295; // show all when undefined
    if (value.isUndefined()) {
        // undefined explicitly passed
        return 4294967295;
    }

    if (value.isNull()) {
        return 0;
    }

    return value.toZig(u32);
}

pub fn getReadyState(self: *const Document) []const u8 {
    return @tagName(self._ready_state);
}

pub fn getActiveElement(self: *Document) ?*Element {
    if (self._active_element) |el| {
        return el;
    }

    // Default to body if it exists
    if (self.is(HTMLDocument)) |html_doc| {
        if (html_doc.getBody()) |body| {
            return body.asElement();
        }
    }

    // Fallback to document element
    return self.getDocumentElement();
}

pub fn getStyleSheets(self: *Document, frame: *Frame) !*StyleSheetList {
    if (self._style_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(frame);
    self._style_sheets = sheets;
    return sheets;
}

pub fn getFonts(self: *Document, frame: *Frame) !*FontFaceSet {
    if (self._fonts) |fonts| {
        return fonts;
    }
    const fonts = try FontFaceSet.init(frame);
    fonts.acquireRef();
    self._fonts = fonts;
    return fonts;
}

pub fn adoptNode(self: *Document, node: *Node, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    const old_owner = node.ownerDocument(frame) orelse frame.document;

    if (node._parent) |parent| {
        frame.removeNode(parent, node, .{ .will_be_reconnected = false });
    }

    if (old_owner != self) {
        try frame.adoptNodeTree(node, old_owner, self);
    }

    return node;
}

pub fn importNode(_: *const Document, node: *Node, deep_: ?bool, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    return node.cloneNode(deep_, frame);
}

pub fn append(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    const parent = self.asNode();
    frame.domChanged();
    const parent_is_connected = parent.isConnected();

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // DocumentFragments are special - append all their children
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.appendAllChildren(child, parent);
            continue;
        }

        var child_connected = false;
        if (child._parent) |previous_parent| {
            child_connected = child.isConnected();
            frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected });
        }
        try frame.appendNode(parent, child, .{ .child_already_connected = child_connected });
    }
}

pub fn prepend(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    const parent = self.asNode();
    frame.domChanged();
    const parent_is_connected = parent.isConnected();

    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(frame);

        // DocumentFragments are special - need to insert all their children
        if (child.is(Node.DocumentFragment)) |frag| {
            const first_child = parent.firstChild();
            var frag_child = frag.asNode().lastChild();
            while (frag_child) |fc| {
                const prev = fc.previousSibling();
                frame.removeNode(frag.asNode(), fc, .{ .will_be_reconnected = parent_is_connected });
                if (first_child) |before| {
                    try frame.insertNodeRelative(parent, fc, .{ .before = before }, .{});
                } else {
                    try frame.appendNode(parent, fc, .{});
                }
                frag_child = prev;
            }
            continue;
        }

        var child_connected = false;
        if (child._parent) |previous_parent| {
            child_connected = child.isConnected();
            frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected });
        }

        const first_child = parent.firstChild();
        if (first_child) |before| {
            try frame.insertNodeRelative(parent, child, .{ .before = before }, .{ .child_already_connected = child_connected });
        } else {
            try frame.appendNode(parent, child, .{ .child_already_connected = child_connected });
        }
    }
}

pub fn replaceChildren(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn moveBefore(self: *Document, node: js.Value, child: js.Value, frame: *Frame) !void {
    return self.asNode().moveBefore(node, child, frame);
}

pub fn elementFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) !?*Element {
    // DFS in document order; topmost = last visited element whose rect contains (x, y).
    //
    // Faux-layout shortcut: rect.top is calculateDocumentPosition × 5, which is
    // monotonically increasing in document order. So we maintain a running
    // preorder counter instead of calling calculateDocumentPosition per node
    // (which itself is O(N)). Once the counter's y passes the query y, no
    // later element can contain the point, and we can return.
    //
    // We also share a single VisibilityCache across all elements so the
    // ancestor-walk inside isHidden gets amortized.
    var topmost: ?*Element = null;

    const root = self.asNode();
    var stack: std.ArrayList(*Node) = .empty;
    try stack.append(frame.local_arena, root);

    var visibility_cache: Element.VisibilityCache = .{};
    var preorder_index: f64 = 0;

    while (stack.items.len > 0) {
        const node = stack.pop() orelse break;
        const pos = preorder_index * 5.0;

        if (pos > y) {
            // Monotonic: no later element has top <= y, so none can contain (x, y).
            return topmost;
        }

        preorder_index += 1;
        if (node.is(Element)) |element| {
            if (element.checkVisibilityCached(&visibility_cache, frame)) {
                const dims = element.getElementDimensions(frame);
                // x and y both come from preorder position in our faux layout.
                const left = pos;
                const top = pos;
                const right = pos + dims.width;
                const bottom = pos + dims.height;
                if (x >= left and x <= right and y >= top and y <= bottom) {
                    topmost = element;
                }
            }
        }

        // Add children to stack in reverse order so we process them in document order
        var child = node.lastChild();
        while (child) |c| {
            try stack.append(frame.local_arena, c);
            child = c.previousSibling();
        }
    }

    return topmost;
}

pub fn elementsFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) ![]const *Element {
    // Get topmost element
    var current: ?*Element = (try self.elementFromPoint(x, y, frame)) orelse return &.{};
    var result: std.ArrayList(*Element) = .empty;
    while (current) |el| {
        try result.append(frame.local_arena, el);
        current = el.parentElement();
    }
    return result.items;
}

pub fn getDocType(self: *Document) ?*Node {
    var tw = @import("TreeWalker.zig").Full.init(self.asNode(), .{});
    while (tw.next()) |node| {
        if (node._type == .document_type) {
            return node;
        }
    }
    return null;
}

// document.write is complicated and works differently based on the state of
// parsing. But, generally, it's supposed to be additive/streaming. Multiple
// document.writes are parsed a single unit. Well, that causes issues with
// html5ever if we're trying to parse 1 document which is really many. So we
// try to detect "new" documents. (This is particularly problematic because we
// don't have proper frame support, so document.write into a frame can get
// sent to the main document (instead of the frame document)...and it's completely
// reasonable for 2 frames to document.write("<html>...</html>") into their own
// frame.
fn looksLikeNewDocument(html: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, html, &std.ascii.whitespace);
    return std.ascii.startsWithIgnoreCase(trimmed, "<!DOCTYPE") or
        std.ascii.startsWithIgnoreCase(trimmed, "<html");
}

pub fn write(self: *Document, text: []const []const u8, frame: *Frame) !void {
    return self.writeInternal(text, false, frame);
}

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#dom-document-writeln
// `writeln(...text)` runs the document write steps with `text` followed by a
// U+000A LINE FEED character.
pub fn writeln(self: *Document, text: []const []const u8, frame: *Frame) !void {
    return self.writeInternal(text, true, frame);
}

fn writeInternal(self: *Document, text: []const []const u8, append_newline: bool, call_frame: *Frame) !void {
    // document.write acts on this document's own frame, which isn't necessarily
    // the calling frame — e.g. a parent frame writing into an iframe's document.
    // The markup (and any scripts it contains) must be parsed and run in that
    // document's context, not the caller's.
    const frame = self._frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    const html = blk: {
        var joined: std.ArrayList(u8) = .empty;
        for (text) |str| {
            // Scratch buffer, consumed synchronously below. Keep it on the
            // active (calling) frame's call_arena: a script run by the parse
            // could reset the document frame's call_arena underfoot.
            try joined.appendSlice(call_frame.call_arena, str);
        }
        if (append_newline) {
            try joined.append(call_frame.call_arena, '\n');
        }
        break :blk joined.items;
    };

    if (self._current_script == null or frame._load_state != .parsing) {
        if (self._script_created_parser == null or looksLikeNewDocument(html)) {
            _ = try self.open(frame);
        }

        if (html.len > 0) {
            if (self._script_created_parser) |*parser| {
                parser.read(html) catch |err| {
                    log.warn(.dom, "document.write parser error", .{ .err = err });
                    // html5ever's handle was destroyed inside read(), but the
                    // pending text buffer (if any) still wants to land on its
                    // text node's _data — flushPendingText doesn't depend on
                    // the handle, so attempt a final flush before dropping.
                    parser.parser.flushPendingText() catch |flush_err| {
                        log.warn(.dom, "flush after parser panic", .{ .err = flush_err });
                    };
                    self._script_created_parser = null;
                    self._close_requested = false;
                };
            }
        }

        if (self._close_requested) {
            // document.close was executed during a document.write. We couldn't
            // execute that during the write, but we can now.
            if (self._script_created_parser) |*parser| {
                if (parser.feeding == false) {
                    try self.finishScriptCreatedParser(frame);
                }
            } else {
                self._close_requested = false;
            }
        }
        return;
    }

    // Inline script during parsing
    const script = self._current_script.?;
    const parent = script.asNode().parentNode() orelse return;

    // Our implementation is hacky. We'll write to a DocumentFragment, then
    // append its children.
    const fragment = try Node.DocumentFragment.init(frame);
    const fragment_node = fragment.asNode();

    const previous_parse_mode = frame._parse_mode;
    frame._parse_mode = .document_write;
    defer frame._parse_mode = previous_parse_mode;

    const arena = try frame.getArena(.medium, "Document.write");
    defer frame.releaseArena(arena);

    var parser = Parser.init(arena, fragment_node, frame, .{ .allow_declarative_shadow = true });
    parser.parseFragment(html);

    // Extract children from wrapper HTML element (html5ever wraps fragments)
    // https://github.com/servo/html5ever/issues/583
    const children = fragment_node._children orelse return;
    const first = Node.linkToNode(children.first.?);

    // Collect all children to insert (to avoid iterator invalidation)
    var children_to_insert: std.ArrayList(*Node) = .empty;

    var it = if (first.is(Element.Html.Html) == null) fragment_node.childrenIterator() else first.childrenIterator();
    while (it.next()) |child| {
        try children_to_insert.append(arena, child);
    }

    if (children_to_insert.items.len == 0) {
        return;
    }

    // Determine insertion point:
    // - If _write_insertion_point is set and still parented correctly, continue from there
    // - Otherwise, start after the script (first write, or previous insertion point was removed)
    // parseFragment above can synchronously execute a parser-blocking script
    // (e.g. <script src=...> with from_parser=true). That script's side
    // effects can detach `script` from `parent` — for instance, by writing
    // to parent.innerHTML — leaving us nowhere sensible to splice in.
    var insert_after: ?*Node = blk: {
        if (self._write_insertion_point) |wip| {
            if (wip._parent == parent) {
                break :blk wip;
            }
        }
        if (script.asNode()._parent == parent) {
            break :blk script.asNode();
        }
        return;
    };

    for (children_to_insert.items) |child| {
        // Clear parent pointer (child is currently parented to fragment/HTML wrapper)
        child._parent = null;
        try frame.insertNodeRelative(parent, child, .{ .after = insert_after.? }, .{});
        insert_after = child;
    }

    frame.domChanged();
    self._write_insertion_point = children_to_insert.getLast();
}

pub fn open(self: *Document, call_frame: *Frame) !*Document {
    const frame = self._frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (frame._load_state == .parsing) {
        return self;
    }

    if (self._script_created_parser != null) {
        return self;
    }

    // If we aren't parsing, then open clears the document.
    const doc_node = self.asNode();

    {
        // Remove all children from document
        var it = doc_node.childrenIterator();
        while (it.next()) |child| {
            frame.removeNode(doc_node, child, .{ .will_be_reconnected = false });
        }
    }

    // reset the document
    self._elements_by_id.clearAndFree(frame.arena);
    self._active_element = null;
    self._open_popovers = .empty;
    self._style_sheets = null;
    self._implementation = null;
    self._ready_state = .loading;

    self._script_created_parser = Parser.Streaming.init(frame.arena, doc_node, frame, .{ .allow_declarative_shadow = true });
    try self._script_created_parser.?.start();
    frame._parse_mode = .document;

    return self;
}

pub fn close(self: *Document, call_frame: *Frame) !void {
    const frame = self._frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (self._script_created_parser) |*parser| {
        if (parser.feeding) {
            // we're currently in a document.write, we cannot close. We flag
            // the close and process it at the next safe spot.
            self._close_requested = true;
            return;
        }
    } else {
        return;
    }

    try self.finishScriptCreatedParser(frame);
}

fn finishScriptCreatedParser(self: *Document, frame: *Frame) !void {
    self._close_requested = false;

    // done() finishes html5ever's handle and runs the final flushPendingText.
    // Even if flushPendingText errors, the handle is already finished and we
    // must not retain the Streaming — defer so the error path also drops it.
    // (Streaming.done nulls its own handle, so dropping the struct is safe.)
    defer self._script_created_parser = null;
    try self._script_created_parser.?.done();

    // The write'd markup is fully parsed; run any deferred scripts it produced
    // (e.g. inline modules) before firing the load event. This frame's initial
    // parse may never have set static_scripts_done (e.g. a freshly-loaded
    // iframe written into via document.write), so we can't rely on it.
    frame._script_manager.base.scriptCreatedParseDone();

    frame.documentIsComplete();
}

pub fn getFirstElementChild(self: *Document) ?*Element {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
    }
    return null;
}

pub fn getLastElementChild(self: *Document) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Document) u32 {
    var i: u32 = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element) != null) {
            i += 1;
        }
    }
    return i;
}

pub fn getAdoptedStyleSheets(self: *Document, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

pub fn hasFocus(_: *Document) bool {
    log.debug(.not_implemented, "Document.hasFocus", .{});
    return true;
}

pub fn setAdoptedStyleSheets(self: *Document, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

// Validates that nodes can be inserted into a Document, respecting Document constraints:
// - At most one Element child
// - At most one DocumentType child
// - No Document, Attribute, or Text nodes
// - Only Element, DocumentType, Comment, and ProcessingInstruction are allowed
// When replacing=true, existing children are not counted (for replaceChildren)
fn validateDocumentNodes(self: *Document, nodes: []const Node.NodeOrText, comptime replacing: bool) !void {
    const parent = self.asNode();

    // Check existing elements and doctypes (unless we're replacing all children)
    var has_element = false;
    var has_doctype = false;

    if (!replacing) {
        var it = parent.childrenIterator();
        while (it.next()) |child| {
            if (child._type == .element) {
                has_element = true;
            } else if (child._type == .document_type) {
                has_doctype = true;
            }
        }
    }

    // Validate new nodes
    for (nodes) |node_or_text| {
        switch (node_or_text) {
            .text => {
                // Text nodes are not allowed as direct children of Document
                return error.HierarchyError;
            },
            .node => |child| {
                // Check if it's a DocumentFragment - need to validate its children
                if (child.is(Node.DocumentFragment)) |frag| {
                    var frag_it = frag.asNode().childrenIterator();
                    while (frag_it.next()) |frag_child| {
                        // Document can only contain: Element, DocumentType, Comment, ProcessingInstruction
                        switch (frag_child._type) {
                            .element => {
                                if (has_element) {
                                    return error.HierarchyError;
                                }
                                has_element = true;
                            },
                            .document_type => {
                                if (has_doctype) {
                                    return error.HierarchyError;
                                }
                                if (has_element) {
                                    // Doctype cannot be inserted if document already has an element
                                    return error.HierarchyError;
                                }
                                has_doctype = true;
                            },
                            .cdata => |cd| switch (cd._type) {
                                .comment, .processing_instruction => {}, // Allowed
                                .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                            },
                            .document, .attribute, .document_fragment => return error.HierarchyError,
                        }
                    }
                } else {
                    // Validate node type for direct insertion
                    switch (child._type) {
                        .element => {
                            if (has_element) {
                                return error.HierarchyError;
                            }
                            has_element = true;
                        },
                        .document_type => {
                            if (has_doctype) {
                                return error.HierarchyError;
                            }
                            if (has_element) {
                                // Doctype cannot be inserted if document already has an element
                                return error.HierarchyError;
                            }
                            has_doctype = true;
                        },
                        .cdata => |cd| switch (cd._type) {
                            .comment, .processing_instruction => {}, // Allowed
                            .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                        },
                        .document, .attribute, .document_fragment => return error.HierarchyError,
                    }
                }

                // Check for cycles
                if (child.contains(parent)) {
                    return error.HierarchyError;
                }
            },
        }
    }
}

// DOM §1.4 "Name validation" productions.

pub fn isValidElementLocalName(name: []const u8) bool {
    if (name.len == 0) {
        return false;
    }
    if (std.ascii.isAlphabetic(name[0])) {
        // Names the HTML parser can construct: anything except ASCII
        // whitespace, NUL, '/' or '>'.
        for (name[1..]) |c| {
            switch (c) {
                '\t', '\n', 0x0C, '\r', ' ', 0, '/', '>' => return false,
                else => {},
            }
        }
        return true;
    }
    // Otherwise the first code point must be ':', '_' or beyond ASCII, and
    // the rest restricted to alphanumerics, '-', '.', ':', '_' or non-ASCII.
    if (name[0] != ':' and name[0] != '_' and name[0] < 0x80) {
        return false;
    }
    for (name[1..]) |c| {
        const valid = std.ascii.isAlphanumeric(c) or
            c == '-' or c == '.' or c == ':' or c == '_' or c >= 0x80;
        if (!valid) {
            return false;
        }
    }
    return true;
}

pub fn isValidNamespacePrefix(prefix: []const u8) bool {
    if (prefix.len == 0) {
        return false;
    }
    for (prefix) |c| {
        switch (c) {
            '\t', '\n', 0x0C, '\r', ' ', 0, '/', '>' => return false,
            else => {},
        }
    }
    return true;
}

pub fn isValidAttributeLocalName(name: []const u8) bool {
    if (name.len == 0) {
        return false;
    }
    for (name) |c| {
        switch (c) {
            '\t', '\n', 0x0C, '\r', ' ', 0, '/', '=', '>' => return false,
            else => {},
        }
    }
    return true;
}

fn validateElementName(name: []const u8) !void {
    if (!isValidElementLocalName(name)) {
        return error.InvalidCharacterError;
    }
}

pub const ValidatedName = struct {
    prefix: ?[]const u8,
    local_name: []const u8,
    namespace: ?[]const u8,
};

// The DOM spec's "validate and extract a namespace and qualifiedName".
pub fn validateAndExtract(namespace_: ?[]const u8, qualified_name: []const u8, comptime context: enum { element, attribute }) !ValidatedName {
    var namespace: ?[]const u8 = namespace_;
    if (namespace) |ns| {
        if (ns.len == 0) {
            namespace = null;
        }
    }

    var prefix: ?[]const u8 = null;
    var local_name = qualified_name;
    if (std.mem.indexOfScalar(u8, qualified_name, ':')) |colon| {
        prefix = qualified_name[0..colon];
        local_name = qualified_name[colon + 1 ..];
        if (!isValidNamespacePrefix(prefix.?)) {
            return error.InvalidCharacterError;
        }
    }

    const local_valid = switch (context) {
        .element => isValidElementLocalName(local_name),
        .attribute => isValidAttributeLocalName(local_name),
    };
    if (!local_valid) {
        return error.InvalidCharacterError;
    }

    if (prefix != null and namespace == null) {
        return error.NamespaceError;
    }
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml") and (namespace == null or !std.mem.eql(u8, namespace.?, "http://www.w3.org/XML/1998/namespace"))) {
            return error.NamespaceError;
        }
    }
    const is_xmlns = std.mem.eql(u8, qualified_name, "xmlns") or (prefix != null and std.mem.eql(u8, prefix.?, "xmlns"));
    const ns_is_xmlns = namespace != null and std.mem.eql(u8, namespace.?, "http://www.w3.org/2000/xmlns/");
    if (is_xmlns != ns_is_xmlns) {
        return error.NamespaceError;
    }

    return .{ .prefix = prefix, .local_name = local_name, .namespace = namespace };
}

// When a frame's URL is about:blank, or as soon as a frame is
// programmatically created, it has this default "blank" content
pub fn injectBlank(self: *Document, frame: *Frame) error{InjectBlankError}!void {
    self._injectBlank(frame) catch |err| {
        // we wrap _injectBlank like this so that injectBlank can only return an
        // InjectBlankError. injectBlank is used in when nodes are inserted
        // as since it inserts node itself, Zig can't infer the error set.
        log.err(.browser, "inject blank", .{ .err = err });
        return error.InjectBlankError;
    };
}

fn _injectBlank(self: *Document, frame: *Frame) !void {
    if (comptime IS_DEBUG) {
        // should only be called on an empty document
        std.debug.assert(self.asNode()._children == null);
    }

    const html = try Frame.node_factory.createElementNS(frame, .html, "html", null);
    const head = try Frame.node_factory.createElementNS(frame, .html, "head", null);
    const body = try Frame.node_factory.createElementNS(frame, .html, "body", null);
    try frame.appendNode(html, head, .{});
    try frame.appendNode(html, body, .{});
    try frame.appendNode(self.asNode(), html, .{});
}

const ReadyState = enum {
    loading,
    interactive,
    complete,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Document);

    pub const Meta = struct {
        pub const name = "Document";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*Document {
        return frame._factory.node(Document{
            ._proto = undefined,
            ._type = .generic,
            ._url = "about:blank",
            ._charset = "UTF-8",
        });
    }

    pub const onselectionchange = bridge.accessor(Document.getOnSelectionChange, Document.setOnSelectionChange, .{});
    pub const onclick = bridge.accessor(Document.getOnClick, Document.setOnClick, .{});
    pub const ontouchstart = bridge.accessor(handlerAccessor(.ontouchstart).get, handlerAccessor(.ontouchstart).set, .{});
    pub const ontouchend = bridge.accessor(handlerAccessor(.ontouchend).get, handlerAccessor(.ontouchend).set, .{});
    pub const ontouchmove = bridge.accessor(handlerAccessor(.ontouchmove).get, handlerAccessor(.ontouchmove).set, .{});
    pub const ontouchcancel = bridge.accessor(handlerAccessor(.ontouchcancel).get, handlerAccessor(.ontouchcancel).set, .{});
    pub const URL = bridge.accessor(Document.getURL, null, .{});
    pub const location = bridge.accessor(Document.getLocation, Document.setLocation, .{});
    pub const documentURI = bridge.accessor(Document.getURL, null, .{});
    pub const documentElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const scrollingElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const children = bridge.accessor(Document.getChildren, null, .{});
    pub const readyState = bridge.accessor(Document.getReadyState, null, .{});
    pub const implementation = bridge.accessor(Document.getImplementation, null, .{});
    pub const activeElement = bridge.accessor(Document.getActiveElement, null, .{});
    pub const styleSheets = bridge.accessor(Document.getStyleSheets, null, .{});
    pub const fonts = bridge.accessor(Document.getFonts, null, .{});
    pub const contentType = bridge.accessor(Document.getContentType, null, .{});
    pub const domain = bridge.accessor(Document.getDomain, Document.setDomain, .{});
    pub const cookie = bridge.accessor(Document.getCookie, Document.setCookie, .{});
    pub const createElement = bridge.function(Document.createElement, .{});
    pub const createElementNS = bridge.function(Document.createElementNS, .{});
    pub const createDocumentFragment = bridge.function(Document.createDocumentFragment, .{});
    pub const createComment = bridge.function(Document.createComment, .{});
    pub const createTextNode = bridge.function(Document.createTextNode, .{});
    pub const createAttribute = bridge.function(Document.createAttribute, .{});
    pub const createAttributeNS = bridge.function(Document.createAttributeNS, .{});
    pub const createCDATASection = bridge.function(Document.createCDATASection, .{});
    pub const createProcessingInstruction = bridge.function(Document.createProcessingInstruction, .{});
    pub const createRange = bridge.function(Document.createRange, .{});
    pub const createEvent = bridge.function(Document.createEvent, .{});
    pub const createTreeWalker = bridge.function(Document.createTreeWalker, .{});
    pub const createNodeIterator = bridge.function(Document.createNodeIterator, .{});
    pub const evaluate = bridge.function(Document.evaluate, .{});
    pub const createExpression = bridge.function(Document.createExpression, .{});
    pub const createNSResolver = bridge.function(Document.createNSResolver, .{});
    pub const getElementById = bridge.function(_getElementById, .{});
    fn _getElementById(self: *Document, value_: ?js.Value, frame: *Frame) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) {
            return self.getElementById("null", frame);
        }
        if (value.isUndefined()) {
            return self.getElementById("undefined", frame);
        }
        return self.getElementById(try value.toZig([]const u8), frame);
    }
    pub const querySelector = bridge.function(Document.querySelector, .{});
    pub const querySelectorAll = bridge.function(Document.querySelectorAll, .{});
    pub const getElementsByTagName = bridge.function(Document.getElementsByTagName, .{});
    pub const getElementsByTagNameNS = bridge.function(Document.getElementsByTagNameNS, .{});
    pub const getSelection = bridge.function(Document.getSelection, .{});
    pub const getElementsByClassName = bridge.function(Document.getElementsByClassName, .{});
    pub const getElementsByName = bridge.function(Document.getElementsByName, .{});
    pub const adoptNode = bridge.function(Document.adoptNode, .{ .ce_reactions = true });
    pub const importNode = bridge.function(Document.importNode, .{ .ce_reactions = true });
    pub const append = bridge.function(Document.append, .{ .ce_reactions = true });
    pub const prepend = bridge.function(Document.prepend, .{ .ce_reactions = true });
    pub const moveBefore = bridge.function(Document.moveBefore, .{ .ce_reactions = true });
    pub const replaceChildren = bridge.function(Document.replaceChildren, .{ .ce_reactions = true });
    pub const elementFromPoint = bridge.function(Document.elementFromPoint, .{});
    pub const elementsFromPoint = bridge.function(Document.elementsFromPoint, .{});
    pub const write = bridge.function(Document.write, .{ .ce_reactions = true });
    pub const writeln = bridge.function(Document.writeln, .{ .ce_reactions = true });
    pub const open = bridge.function(Document.open, .{ .ce_reactions = true });
    pub const close = bridge.function(Document.close, .{ .ce_reactions = true });
    pub const doctype = bridge.accessor(Document.getDocType, null, .{});
    pub const firstElementChild = bridge.accessor(Document.getFirstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Document.getLastElementChild, null, .{});
    pub const childElementCount = bridge.accessor(Document.getChildElementCount, null, .{});
    pub const adoptedStyleSheets = bridge.accessor(Document.getAdoptedStyleSheets, Document.setAdoptedStyleSheets, .{});
    pub const hidden = bridge.property(false, .{ .template = false, .readonly = true });
    pub const visibilityState = bridge.property("visible", .{ .template = false, .readonly = true });
    pub const defaultView = bridge.accessor(struct {
        fn defaultView(self: *const Document) ?*@import("Window.zig") {
            const frame = self._frame orelse return null;
            return frame.window;
        }
    }.defaultView, null, .{});
    pub const hasFocus = bridge.function(Document.hasFocus, .{});

    pub const prerendering = bridge.property(false, .{ .template = false });
    pub const characterSet = bridge.accessor(getCharacterSet, null, .{});
    pub const charset = bridge.accessor(getCharacterSet, null, .{});
    pub const inputEncoding = bridge.accessor(getCharacterSet, null, .{});
    pub const compatMode = bridge.accessor(Document.getCompatMode, null, .{});
    fn getCharacterSet(self: *const Document) []const u8 {
        return self.getCharset();
    }
    pub const referrer = bridge.property("", .{ .template = false });

    // Generates a getter/setter pair backed by the frame's attribute-listener
    // map, like onclick above, for other document event handler properties.
    fn handlerAccessor(comptime handler: @import("global_event_handlers.zig").Handler) type {
        return struct {
            pub fn get(self: *Document, frame: *Frame) ?js.Function.Global {
                const owner = self._frame orelse frame;
                return owner._event_target_attr_listeners.get(.{ .target = self.asEventTarget(), .handler = handler });
            }

            pub fn set(self: *Document, setter: ?Window.FunctionSetter, frame: *Frame) !void {
                const owner = self._frame orelse frame;
                if (Window.getFunctionFromSetter(setter)) |cb| {
                    try owner._event_target_attr_listeners.put(owner.arena, .{ .target = self.asEventTarget(), .handler = handler }, cb);
                } else {
                    _ = owner._event_target_attr_listeners.remove(.{ .target = self.asEventTarget(), .handler = handler });
                }
            }
        };
    }
};

const testing = @import("../../testing.zig");
test "WebApi: Document" {
    try testing.htmlRunner("document", .{});
}

test "WebApi: Document.evaluate" {
    try testing.htmlRunner("xpath/document_evaluate.html", .{});
}

test "Document: isRelaxableTo" {
    // Pure opt-in (relax to self) is always allowed, including IP hosts.
    try testing.expectEqual(true, isRelaxableTo("a.example.com", "a.example.com"));
    try testing.expectEqual(true, isRelaxableTo("127.0.0.1", "127.0.0.1"));

    // Relaxing to a registrable superdomain.
    try testing.expectEqual(true, isRelaxableTo("a.example.com", "example.com"));
    try testing.expectEqual(true, isRelaxableTo("a.b.example.com", "example.com"));
    try testing.expectEqual(true, isRelaxableTo("a.b.example.com", "b.example.com"));

    // Bare TLDs (single label) are never registrable. Multi-label public
    // suffixes are rejected via the PSL — note the test build stubs the PSL
    // to {gov.uk, api.gov.uk}, so those are the entries exercised here.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "com"));
    try testing.expectEqual(false, isRelaxableTo("foo.gov.uk", "gov.uk"));
    try testing.expectEqual(false, isRelaxableTo("a.api.gov.uk", "api.gov.uk"));
    // ...but a registrable domain sitting under that suffix is fine.
    try testing.expectEqual(true, isRelaxableTo("a.dept.gov.uk", "dept.gov.uk"));

    // Must be a label-boundary suffix, not a substring suffix.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "ample.com"));
    try testing.expectEqual(false, isRelaxableTo("notexample.com", "example.com"));

    // Unrelated domain, and the empty string.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "example.org"));
    try testing.expectEqual(false, isRelaxableTo("a.example.com", ""));
}
