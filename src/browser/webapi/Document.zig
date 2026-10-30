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

const idna = @import("../../sys/idna.zig");
const public_suffix_list = @import("../../data/public_suffix_list.zig");

const EventTarget = @import("EventTarget.zig");
const URL = @import("../URL.zig");
const IdMap = @import("../IdMap.zig");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");
const Parser = @import("../parser/Parser.zig");

const Node = @import("Node.zig");
const Window = @import("Window.zig");
const Element = @import("Element.zig");
const Location = @import("Location.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const TreeWalker = @import("TreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");
const StyleSheetList = @import("css/StyleSheetList.zig");
const FontFaceSet = @import("css/FontFaceSet.zig");
const Selection = @import("Selection.zig");
const Sanitizer = @import("Sanitizer.zig");
const XPathResult = @import("XPathResult.zig");
const XPathExpression = @import("XPathExpression.zig");
const exec_command = @import("../frame/exec_command.zig");

pub const XMLDocument = @import("XMLDocument.zig");
pub const HTMLDocument = @import("HTMLDocument.zig");

const log = lp.log;
const String = lp.String;

const Document = @This();

pub const Proto = Node;

_type: Type,
_proto: *Node,
_page: *Page,
_index: u32, // browser.documents index
_frame: ?*Frame = null,
_template_contents_owner: ?*Document = null,
_url: ?[:0]const u8 = null, // URL for documents created via DOMImplementation (about:blank)
// content type override for documents created via DOMImplementation.createDocument
_content_type: ?[]const u8 = null,
// encoding override: documents synthesized by script (createHTMLDocument,
// createDocument) are UTF-8 regardless of the frame's encoding
_charset: ?[]const u8 = null,
_ready_state: ReadyState = .loading,
_load_aborted: bool = false,
// HTML's "active parser was aborted" flag also makes open/write no-ops.
_active_parser_aborted: bool = false,
// Its frame navigated to another document: open/write are no-ops.
_navigated_away: bool = false,
// The iframe load event steps' flags: a document.open() while the element's
// load event fires for this document mutes its later ones.
_iframe_load_in_progress: bool = false,
_mute_iframe_load: bool = false,
_current_script: ?*Element.Html.Script = null,
_ids: IdMap = .{},
_active_element: ?*Element = null,
_style_sheets: ?*StyleSheetList = null,
_implementation: ?*DOMImplementation = null,
_fonts: ?*FontFaceSet = null,
_write_insertion_point: ?*Node = null,
_script_created_parser: ?Parser.Streaming = null,
_close_requested: bool = false,
// an execCommand is running: a nested one is refused
_exec_command_running: bool = false,
_design_mode: bool = false,
_adopted_style_sheets: ?js.Object.Global = null,
_selection: Selection = .{ ._rc = .init(1) },
// extent() cache, keyed on style version and viewport.
_extent: ?struct {
    version: usize,
    viewport_width: u32,
    viewport_height: u32,
    extent: Extent,
} = null,
// Ordered stack of currently-showing popovers
_open_popovers: std.ArrayList(*Element) = .empty,
// Ordered stack of dialogs opened with showModal(), topmost last. Stands in
// for the top layer and the close watchers those dialogs establish.
_modal_dialogs: std.ArrayList(*Element.Html.Dialog) = .empty,

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#throw-on-dynamic-markup-insertion-counter
// Incremented during custom element reactions when parsing. When > 0,
// document.open/close/write/writeln must throw InvalidStateError.
_throw_on_dynamic_markup_insertion_counter: u32 = 0,

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

pub fn asEventTarget(self: *Document) *EventTarget {
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

fn setLocation(self: *Document, url: [:0]const u8) !void {
    if (self._type != .html) return;
    const frame = self._frame orelse return;
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = Location.historyHandling(frame) }, .{ .script = frame });
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

fn getDesignMode(self: *const Document) []const u8 {
    return if (self._design_mode) "on" else "off";
}

// Values other than "on" and "off" are ignored.
fn setDesignMode(self: *Document, value: []const u8, frame: *Frame) void {
    const on = if (std.ascii.eqlIgnoreCase(value, "on"))
        true
    else if (std.ascii.eqlIgnoreCase(value, "off"))
        false
    else
        return;
    if (on != self._design_mode) {
        self._design_mode = on;
        // :read-write now matches differently
        frame.styleChanged();
    }
}

fn getCompatMode(self: *const Document) []const u8 {
    return if (self.isQuirksMode()) "BackCompat" else "CSS1Compat";
}

// document.lastModified: the response's Last-Modified header in local time,
// "MM/DD/YYYY hh:mm:ss", defaulting to the current time.
fn getLastModified(self: *const Document, frame: *Frame) ![]const u8 {
    const dt = @import("../../datetime.zig");

    const timestamp = blk: {
        if (self._frame) |owner| {
            for (owner._http_headers.items) |header| {
                if (std.mem.eql(u8, header.name, "last-modified")) {
                    if (dt.DateTime.parse(header.value, .rfc822)) |parsed| {
                        break :blk parsed.unix(.seconds);
                    } else |_| {}
                    break;
                }
            }
        }
        // localTime is signed: a parsed Last-Modified can predate the epoch
        break :blk @as(i64, @intCast(lp.datetime.timestamp(.real)));
    };

    const tm = try dt.localTime(timestamp);
    return frame.local_arena.print("{d:0>2}/{d:0>2}/{d} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        tm.tm_year + 1900,
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    });
}

fn getReferrer(self: *const Document) []const u8 {
    const frame = self._frame orelse return "";
    return frame._referrer orelse "";
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

fn getDomain(self: *const Document, frame: *const Frame) []const u8 {
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

fn setDomain(self: *Document, value: []const u8) !void {
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
    const scheme_end = (std.mem.find(u8, origin, "://") orelse return error.SecurityError) + 3;
    const key = try std.mem.concat(arena, u8, &.{ "!", origin[0..scheme_end], requested });
    try doc_frame.js.setOrigin(key);
}

// A cookie-averse document (no browsing context: createHTMLDocument,
// DOMParser, XHR documents) reads cookies as the empty string and ignores
// writes.
fn isCookieAverse(self: *const Document, frame: *const Frame) bool {
    const doc_frame = self._frame orelse return true;
    return doc_frame.document != self and frame.document != self;
}

fn getCookie(self: *Document, frame: *Frame) ![]const u8 {
    if (self.isCookieAverse(frame)) {
        return "";
    }
    var aw: std.Io.Writer.Allocating = .init(frame.local_arena);
    try frame._session.cookie_jar.forRequest(frame.url, &aw.writer, .{
        .is_http = false,
        .kind = .subresource,
        .origin_url = frame.siteForCookies(),
    });
    return aw.written();
}

pub fn setCookie(self: *Document, cookie_str: []const u8, frame: *Frame) ![]const u8 {
    if (self.isCookieAverse(frame)) {
        return cookie_str;
    }
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
    if (c.same_site != .none and frame.siteForCookies() == .none) {
        c.deinit();
        return ""; // SameSite cookies cannot be set from a cross-site context.
    }
    try frame._session.cookie_jar.addFromUrl(frame.url, c, lp.datetime.timestamp(.real), false);
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
    if (std.mem.findScalar(u8, requested, '.') == null) {
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
            const lower = if (Element.Attribute.needsLowerCasing(name))
                try std.ascii.allocLowerString(frame.local_arena, name)
            else
                name;
            break :blk .{ .html, lower };
        }
        // Generic and XML documents create elements with null namespace
        break :blk .{ .null, name };
    };
    // HTML documents are case-insensitive - lowercase the tag name

    const node = try self.createElementNode(ns, normalized_name);
    const element = node.as(Element);

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
    const node = try self.createElementNode(ns, name);

    // Store original URI for unknown namespaces so lookupNamespaceURI can return it
    if (ns == .unknown) {
        if (namespace) |uri| {
            const duped = try frame.dupeString(uri);
            try self._page.element_namespace_uris.put(self._page.arena, node.as(Element), duped);
        }
    }
    return node.as(Element);
}

fn createElementNode(self: *Document, ns: Element.Namespace, name: []const u8) !*Node {
    return Frame.node_factory.createElementNS(self, ns, name, null);
}

fn createAttribute(self: *const Document, name: String.Global, frame: *Frame) !?*Element.Attribute {
    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(self, Element.Attribute{
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn createAttributeNS(self: *const Document, namespace: []const u8, name: String.Global, frame: *Frame) !?*Element.Attribute {
    if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml") == false) {
        log.debug(.not_implemented, "document.createAttributeNS", .{ .namespace = namespace });
    }

    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(self, Element.Attribute{
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn getElementById(self: *Document, id: []const u8) ?*Element {
    if (id.len == 0) {
        return null;
    }
    return self._ids.get(self.asNode(), id);
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

fn getElementsByName(self: *Document, name: []const u8, frame: *Frame) !collections.NodeLive(.name) {
    const arena = frame.page_arena;
    const filter = try arena.dupe(u8, name);
    return collections.NodeLive(.name).init(self.asNode(), filter, frame);
}

fn getChildren(self: *Document, frame: *Frame) !collections.NodeLive(.child_elements) {
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

pub const Extent = struct { width: f64, height: f64 };

/// The document's size. Height: enough for every synthetic position (5px per
/// node), the bottom of every element with an inline height, and body's
/// stacked children. Width: body's widest child. An inline size on body
/// stretches both. A document without a frame isn't rendered, so it has no
/// size.
pub fn extent(self: *Document) Extent {
    const frame = self._frame orelse return .{ .width = 0, .height = 0 };
    const version = frame.page.style_version;
    const viewport = frame.page.getViewport();
    if (self._extent) |cached| {
        if (cached.version == version and cached.viewport_width == viewport.width and cached.viewport_height == viewport.height) {
            return cached.extent;
        }
    }

    const style_manager = &frame._style_manager;
    var size: Extent = .{ .width = 0, .height = 0 };

    // A nested spacer (virtualized lists) must extend the document even when
    // its auto-height ancestors count as 5px each. Body's own children are
    // stacked below instead. Only inline heights: virtualizers set theirs
    // inline, and the cascade per element is too slow on every mutation.
    // Walks the flat tree, the order Element positions are numbered in.
    var index: f64 = 0;
    var tw: TreeWalker.Flat = .init(self.asNode(), .{ .frame = frame });
    while (tw.next()) |node| : (index += 1) {
        const el = node.is(Element) orelse continue;
        const parent = el.asNode().flatTreeParentElement(frame) orelse continue;
        if (parent.isRootContainer()) {
            continue;
        }
        if (style_manager.inlineSize(el, .height)) |height| {
            size.height = @max(size.height, index * 5.0 + height);
        }
    }
    size.height = @max(size.height, index * 5.0);

    if (self.is(HTMLDocument) != null) {
        if (self.getBody()) |html_body| {
            const body = html_body.asElement();
            size.height = @max(size.height, body.contentAxis(frame, .height), style_manager.inlineSize(body, .height) orelse 0);
            size.width = style_manager.inlineSize(body, .width) orelse 0;
            var children: TreeWalker.FlatChildren = .init(body.asNode(), .{ .frame = frame });
            while (children.next()) |node| {
                const el = node.is(Element) orelse continue;
                if (!style_manager.hasDisplayNone(el)) {
                    size.width = @max(size.width, el.getElementAxis(frame, .width).value);
                }
            }
        }
    }

    // Whole pixels, like scroll offsets
    size = .{ .width = @ceil(size.width), .height = @ceil(size.height) };
    self._extent = .{
        .version = version,
        .viewport_width = viewport.width,
        .viewport_height = viewport.height,
        .extent = size,
    };
    return size;
}

/// What the viewport scrolls over: the document, at least viewport-sized.
pub fn scrollSize(self: *Document) Extent {
    const frame = self._frame orelse return .{ .width = 0, .height = 0 };
    const size = self.extent();
    const viewport = frame.page.getViewport();
    return .{
        .width = @max(size.width, @as(f64, @floatFromInt(viewport.width))),
        .height = @max(size.height, @as(f64, @floatFromInt(viewport.height))),
    };
}

fn getSelection(self: *Document) *Selection {
    return &self._selection;
}

pub fn querySelector(self: *Document, input: String, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), input.str(), frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn querySelectorAll(self: *Document, input: String, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input.str(), frame) catch |err| Selector.mapErrorToDOM(err);
}

fn getImplementation(self: *Document, frame: *Frame) !*DOMImplementation {
    if (self._implementation) |impl| return impl;
    const impl = try frame._factory.create(DOMImplementation{ ._document = self });
    self._implementation = impl;
    return impl;
}

fn createDocumentFragment(self: *Document, frame: *Frame) !*Node.DocumentFragment {
    return Node.DocumentFragment.init(self, frame);
}

// https://html.spec.whatwg.org/multipage/scripting.html#appropriate-template-contents-owner-document
// A <template>'s content lives in a document with no browsing context, shared
// by every template of this document (and by the templates nested in that
// content). Nothing in there is connected, scripts never run and, having no
// custom element registry, custom elements are never constructed.
//
// Only a copy stamped into a real document gets upgraded.
pub fn templateContentsOwner(self: *Document, frame: *Frame) !*Document {
    if (self._template_contents_owner) |owner| {
        return owner;
    }

    const owner: *Document = if (self._type == .html)
        (try frame._factory.document(HTMLDocument{ ._proto = undefined })).asDocument()
    else
        try frame._factory.genericDocument(.{});
    owner._url = "about:blank";
    owner._charset = "UTF-8";
    owner._ready_state = .complete;
    // Its own templates' content stays in it.
    owner._template_contents_owner = owner;

    self._template_contents_owner = owner;
    return owner;
}

pub fn createComment(self: *Document, data: []const u8) !*Node {
    return Frame.node_factory.createComment(self, data);
}

pub fn createTextNode(self: *Document, data: []const u8) !*Node {
    return Frame.node_factory.createTextNode(self, data);
}

pub fn createCDATASection(self: *Document, data: []const u8) !*Node {
    return switch (self._type) {
        .html => error.NotSupported, // cannot create a CDataSection in an HTMLDocument
        .xml, .generic => Frame.node_factory.createCDATASection(self, data),
    };
}

pub fn createProcessingInstruction(self: *Document, target: []const u8, data: []const u8) !*Node {
    return Frame.node_factory.createProcessingInstruction(self, target, data);
}

const Range = @import("Range.zig");
fn createRange(self: *Document, frame: *Frame) !*Range {
    return Range.initIn(self.asNode(), frame);
}

fn createEvent(_: *const Document, event_type: []const u8, frame: *Frame) !*@import("Event.zig") {
    const Event = @import("Event.zig");
    if (event_type.len > 100) {
        return error.NotSupported;
    }
    const normalized = try std.ascii.allocLowerString(frame.local_arena, event_type);

    const event: *Event = blk: {
        if (std.mem.eql(u8, normalized, "event") or std.mem.eql(u8, normalized, "events") or std.mem.eql(u8, normalized, "htmlevents") or std.mem.eql(u8, normalized, "svgevents")) {
            break :blk try Event.init("", null, frame.page);
        }

        if (std.mem.eql(u8, normalized, "customevent")) {
            const CustomEvent = @import("event/CustomEvent.zig");
            break :blk (try CustomEvent.init("", null, frame.page)).asEvent();
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
            break :blk (try MessageEvent.init("", null, frame.page)).asEvent();
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

fn createTreeWalker(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMTreeWalker.FilterOpts, frame: *Frame) !*DOMTreeWalker {
    return DOMTreeWalker.init(root, try whatToShow(what_to_show), filter, frame);
}

fn createNodeIterator(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMNodeIterator.FilterOpts, frame: *Frame) !*DOMNodeIterator {
    return DOMNodeIterator.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn evaluate(
    self: *Document,
    expression: []const u8,
    context_node: ?*Node,
    resolver: ?js.Value,
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

fn createExpression(
    _: *const Document,
    expression: []const u8,
    resolver: ?js.Value,
    frame: *Frame,
) !*XPathExpression {
    _ = resolver;
    return XPathExpression.init(expression, frame);
}

fn createNSResolver(_: *const Document, node: *Node) ?*Node {
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

fn getReadyState(self: *const Document) []const u8 {
    return @tagName(self._ready_state);
}

pub fn getActiveElement(self: *Document) ?*Element {
    if (self._active_element) |el| {
        // A focused element inside a shadow tree is exposed as its outermost
        // host; one in a detached tree isn't exposed at all.
        var candidate = el;
        while (candidate.asNode().containingShadowRoot()) |shadow| {
            candidate = shadow._host;
        }
        if (candidate.asNode().getRootNode(.{}) == self.asNode()) {
            return candidate;
        }
    }

    // Default to body if it exists
    if (self.is(HTMLDocument) != null) {
        if (self.getBody()) |body| {
            return body.asElement();
        }
    }

    // Fallback to document element
    return self.getDocumentElement();
}

/// Focus takes part in the cascade (`:focus`, `:focus-within`), so every write
/// to `_active_element` has to go through here to stamp the style version.
pub fn setActiveElement(self: *Document, element: ?*Element, frame: *Frame) void {
    if (self._active_element == element) {
        return;
    }
    self._active_element = element;
    frame.styleChanged();
}

pub fn getStyleSheets(self: *Document, frame: *Frame) !*StyleSheetList {
    if (self._style_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(frame);
    self._style_sheets = sheets;
    return sheets;
}

fn getFonts(self: *Document, frame: *Frame) !*FontFaceSet {
    if (self._fonts) |fonts| {
        return fonts;
    }
    const fonts = try FontFaceSet.init(frame);
    fonts.acquireRef();
    self._fonts = fonts;
    return fonts;
}

fn adoptNode(self: *Document, node: *Node, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }
    if (node.is(Node.ShadowRoot) != null) {
        return error.HierarchyError;
    }

    const old_owner = node.ownerDocument(frame).?;

    if (node._parent) |parent| {
        frame.removeNode(parent, node, .{ .reconnect_to = null });
    }

    if (old_owner != self) {
        try frame.adoptNodeTree(node, old_owner, self);
    }

    return node;
}

fn importNode(self: *const Document, node: *Node, deep_: ?bool, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    return node.cloneNodeInto(deep_ orelse false, self, frame);
}

pub fn append(self: *Document, nodes: js.Variadic(Node.NodeOrText), frame: *Frame) !void {
    try validateDocumentNodes(self, nodes.values);

    const parent = self.asNode();
    frame.domChanged();

    for (nodes.values) |node_or_text| {
        const child = try node_or_text.toNode(self);

        // DocumentFragments are special - append all their children
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.appendAllChildren(child, parent);
            continue;
        }

        var previous_root: ?*Node = null;
        if (child._parent) |previous_parent| {
            previous_root = child.getRootNode(.{});
            frame.removeNode(previous_parent, child, .{ .reconnect_to = parent });
        }
        try frame.appendNode(parent, child, .{ .previous_root = previous_root });
    }
}

pub fn prepend(self: *Document, nodes: js.Variadic(Node.NodeOrText), frame: *Frame) !void {
    try validateDocumentNodes(self, nodes.values);

    const parent = self.asNode();
    frame.domChanged();

    var i = nodes.values.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes.values[i].toNode(self);

        // DocumentFragments are special - need to insert all their children
        if (child.is(Node.DocumentFragment)) |frag| {
            const first_child = parent.firstChild();
            var frag_child = frag.asNode().lastChild();
            while (frag_child) |fc| {
                const prev = fc.previousSibling();
                frame.removeNode(frag.asNode(), fc, .{ .reconnect_to = parent });
                if (first_child) |before| {
                    try frame.insertNodeRelative(parent, fc, .{ .before = before }, .{});
                } else {
                    try frame.appendNode(parent, fc, .{});
                }
                frag_child = prev;
            }
            continue;
        }

        var previous_root: ?*Node = null;
        if (child._parent) |previous_parent| {
            previous_root = child.getRootNode(.{});
            frame.removeNode(previous_parent, child, .{ .reconnect_to = parent });
        }

        const first_child = parent.firstChild();
        if (first_child) |before| {
            try frame.insertNodeRelative(parent, child, .{ .before = before }, .{ .previous_root = previous_root });
        } else {
            try frame.appendNode(parent, child, .{ .previous_root = previous_root });
        }
    }
}

pub fn replaceChildren(self: *Document, nodes: js.Variadic(Node.NodeOrText), frame: *Frame) !void {
    return self.asNode().replaceChildren(nodes.values, frame);
}

pub fn moveBefore(self: *Document, node: js.Value, child: js.Value, frame: *Frame) !void {
    return self.asNode().moveBefore(node, child, frame);
}

/// The deepest element at the point, shadow trees included
pub fn hitTest(self: *Document, x: f64, y: f64, frame: *Frame) !?*Element {
    return self.hitTestImpl(x, y, false, frame);
}

// document.elementFromPoint only sees the document's tree: a hit inside a
// shadow tree reports its outermost host, as in Chrome.
fn elementFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) !?*Element {
    return self.elementFromPointIn(self.asNode(), x, y, frame);
}

/// DocumentOrShadowRoot.elementFromPoint for `scope`, this document or one of
/// its shadow roots.
pub fn elementFromPointIn(self: *Document, scope: *Node, x: f64, y: f64, frame: *Frame) !?*Element {
    const point = viewportPoint(x, y, frame) orelse return null;
    const hit = (try self.hitTest(point.x, point.y, frame)) orelse return null;
    return retarget(hit, scope);
}

const ViewportPoint = struct { x: f64, y: f64 };

// elementFromPoint/elementsFromPoint find nothing outside the viewport
fn viewportPoint(x: f64, y: f64, frame: *Frame) ?ViewportPoint {
    const viewport = frame.page.getViewport();
    const rx = @round(x);
    const ry = @round(y);
    const inside = rx >= 0 and ry >= 0 and
        rx < @as(f64, @floatFromInt(viewport.width)) and
        ry < @as(f64, @floatFromInt(viewport.height));
    if (inside == false) {
        return null;
    }
    return .{ .x = rx, .y = ry };
}

// The spec's retarget: climbs out of shadow trees until `element` is in a tree
// that `scope` is in or inside of. A hit in a shadow tree nested in `scope`'s
// reports its host in `scope`'s tree; a hit outside it is returned as is.
fn retarget(element: *Element, scope: *Node) *Element {
    var current = element;
    while (current.asNode().containingShadowRoot()) |shadow| {
        if (shadow.asNode().isHostIncludingInclusiveAncestorOf(scope)) {
            break;
        }
        current = shadow._host;
    }
    return current;
}

// The faux layout gives most elements no useful horizontal extent, so
// viewport-relative hit-testing (WebDriver scroll actions) matches on the
// vertical axis only.
pub fn hitTestVertical(self: *Document, y: f64, frame: *Frame) !?*Element {
    return self.hitTestImpl(0, y, true, frame);
}

fn hitTestImpl(self: *Document, viewport_x: f64, viewport_y: f64, ignore_x: bool, frame: *Frame) !?*Element {
    // DFS in flat-tree order (shadow content inside its host, slotted nodes
    // inside their slot, as Element.calculateDocumentPosition lays them out);
    // topmost = last visited element whose rect contains (x, y).
    //
    // Faux-layout shortcut: rect.top is calculateDocumentPosition × 5, which is
    // monotonically increasing in document order. So we maintain a running
    // preorder counter instead of calling calculateDocumentPosition per node
    // (which itself is O(N)). Once the counter's y passes the query y, no
    // later element can contain the point, and we can return.
    //
    // Hidden subtrees still count towards the index so positions agree with
    // getBoundingClientRect; the hidden verdict just rides down the stack.
    var topmost: ?*Element = null;

    const root = self.asNode();
    const owner = root.ownerFrame(frame) orelse return null;
    const style_manager = &owner._style_manager;

    // (x, y) is viewport-relative; the faux layout is in document coordinates.
    const x = viewport_x + @as(f64, @floatFromInt(owner.window.getScrollX()));
    const y = viewport_y + @as(f64, @floatFromInt(owner.window.getScrollY()));

    const Entry = struct { node: *Node, hidden: bool };
    var stack: std.ArrayList(Entry) = .empty;
    try stack.append(frame.local_arena, .{ .node = root, .hidden = false });

    var preorder_index: f64 = 0;

    while (stack.items.len > 0) {
        const entry = stack.pop() orelse break;
        const node = entry.node;
        var hidden = entry.hidden;
        const pos = preorder_index * 5.0;

        if (pos > y) {
            // Monotonic: no later element has top <= y, so none can contain (x, y).
            return topmost;
        }

        preorder_index += 1;
        if (node.is(Element)) |element| {
            hidden = hidden or style_manager.hasDisplayNone(element);
            // Unlike display:none, a child can opt back in, so the subtree is
            // still walked.
            if (!hidden and style_manager.isHitTestable(element)) {
                if (y >= pos and y <= pos + element.boxAxis(frame, .height)) {
                    if (ignore_x) {
                        topmost = element;
                    } else {
                        // only bother calculating the horiziontal position for
                        // elements contained by the vertical band
                        const left = element.horizontalPosition(frame);
                        if (x >= left and x <= left + element.boxAxis(frame, .width)) {
                            topmost = element;
                        }
                    }
                }
            }
        }

        // Push the children, then reverse them so they pop in flat-tree order
        const first = stack.items.len;
        var children: TreeWalker.FlatChildren = .init(node, .{ .frame = frame });
        while (children.next()) |c| {
            try stack.append(frame.local_arena, .{ .node = c, .hidden = hidden });
        }
        std.mem.reverse(Entry, stack.items[first..]);
    }

    return topmost;
}

fn elementsFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) ![]const *Element {
    return self.elementsFromPointIn(self.asNode(), x, y, frame);
}

/// DocumentOrShadowRoot.elementsFromPoint for `scope`, as Blink builds it: the
/// hit and its flat-tree ancestors that can be hit, each retargeted against
/// `scope` with repeats dropped, then the root element.
pub fn elementsFromPointIn(self: *Document, scope: *Node, x: f64, y: f64, frame: *Frame) ![]const *Element {
    const point = viewportPoint(x, y, frame) orelse return &.{};
    const hit = (try self.hitTest(point.x, point.y, frame)) orelse return &.{};
    const style_manager = &(self.asNode().ownerFrame(frame) orelse return &.{})._style_manager;
    var result: std.ArrayList(*Element) = .empty;
    var current: ?*Element = hit;
    while (current) |el| : (current = el.asNode().flatTreeParentElement(frame)) {
        if (style_manager.isHitTestable(el) == false) {
            continue;
        }
        const target = retarget(el, scope);
        if (result.items.len > 0 and result.items[result.items.len - 1] == target) {
            continue;
        }
        try result.append(frame.local_arena, target);
    }
    // Chrome always ends the list with the root element.
    if (self.getDocumentElement()) |root| {
        if (result.items.len == 0 or result.items[result.items.len - 1] != root) {
            try result.append(frame.local_arena, root);
        }
    }
    return result.items;
}

fn getDocType(self: *Document) ?*Node {
    var tw = TreeWalker.Full.init(self.asNode(), .{});
    while (tw.next()) |node| {
        if (node._type == .document_type) {
            return node;
        }
    }
    return null;
}

// The head is the first html-namespace child of the document element whose
// local name is head, whatever its Zig element type (e.g. a createElementNS
// "blah:head" is an HTMLUnknownElement but still qualifies).
pub fn getHead(self: *Document) ?*Element {
    const doc_el = self.getDocumentElement() orelse return null;
    var it = doc_el.asNode().childrenIterator();
    while (it.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (el._namespace == .html and std.mem.eql(u8, el.getLocalName(), "head")) {
            return el;
        }
    }
    return null;
}

// The body element: the first <body> or <frameset> child of <html>.
pub fn getBody(self: *Document) ?*Element.Html {
    const document_element = self.getDocumentElement() orelse return null;
    return findBodyForDoc(document_element);
}

// https://html.spec.whatwg.org/multipage/dom.html#dom-document-body
fn setBody(self: *Document, value: ?*Element.Html, frame: *Frame) !void {
    const new_body = value orelse return error.HierarchyError;
    if (isBodyElement(new_body) == false) {
        return error.HierarchyError;
    }

    const document_element = self.getDocumentElement() orelse return error.HierarchyError;
    const document_node = document_element.asNode();
    if (findBodyForDoc(document_element)) |current| {
        if (current == new_body) {
            return;
        }
        _ = try document_node.replaceChild(new_body.asNode(), current.asNode(), frame);
    } else {
        _ = try document_node.appendChild(new_body.asNode(), frame);
    }
}

fn findBodyForDoc(document_element: *Element) ?*Element.Html {
    var child = document_element.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html)) |html| {
            if (isBodyElement(html)) {
                return html;
            }
        }
        child = node.nextSibling();
    }
    return null;
}

fn isBodyElement(html: *Element.Html) bool {
    return html.is(Element.Html.Body) != null or html.asElement().getTag() == .frameset;
}

pub fn getTitle(self: *Document, frame: *Frame) ![]const u8 {
    // Search the entire document for the first <title> element
    const root = self.getDocumentElement() orelse return "";
    var walker = TreeWalker.Full.ElementsOf(Element.Html.Title).init(root.asNode(), .{});
    const title_element = walker.next() orelse return "";

    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try title_element.asNode().getTextContent(&buf.writer);
    const text = buf.written();

    if (text.len == 0) {
        return "";
    }

    var started = false;
    var in_whitespace = false;
    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacityPrecise(frame.local_arena, text.len);

    for (text) |c| {
        const is_ascii_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0C';

        if (is_ascii_ws) {
            if (started) {
                in_whitespace = true;
            }
        } else {
            if (in_whitespace) {
                result.appendAssumeCapacity(' ');
                in_whitespace = false;
            }
            result.appendAssumeCapacity(c);
            started = true;
        }
    }

    return result.items;
}

fn setTitle(self: *Document, title: []const u8, frame: *Frame) !void {
    const head = self.getHead() orelse return;

    // Find existing title element in head
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element.Html.Title)) |title_element| {
            // Replace children, but don't create text node for empty string
            if (title.len == 0) {
                return title_element.asElement().replaceChildren(.init(&.{}), frame);
            } else {
                return title_element.asElement().replaceChildren(.init(&.{.{ .text = title }}), frame);
            }
        }
    }

    // No title element found, create one
    const title_node = try Frame.node_factory.createElementNS(self, .html, "title", null);
    const title_element = title_node.as(Element);

    // Only add text if non-empty
    if (title.len > 0) {
        try title_element.replaceChildren(.init(&.{.{ .text = title }}), frame);
    }

    _ = try head.asNode().appendChild(title_node, frame);
}

fn getImages(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .img, frame);
}

fn getScripts(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .script, frame);
}

fn getLinks(self: *Document, frame: *Frame) !collections.NodeLive(.links) {
    return collections.NodeLive(.links).init(self.asNode(), {}, frame);
}

fn getAnchors(self: *Document, frame: *Frame) !collections.NodeLive(.anchors) {
    return collections.NodeLive(.anchors).init(self.asNode(), {}, frame);
}

fn getForms(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .form, frame);
}

fn getEmbeds(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .embed, frame);
}

fn getApplets(_: *const Document, frame: *Frame) !*collections.HTMLCollection {
    return frame._factory.create(collections.HTMLCollection{ ._data = .empty });
}

fn getCurrentScript(self: *const Document) ?*Element.Html.Script {
    return self._current_script;
}

fn getDir(self: *Document) []const u8 {
    const el = self.getDocumentElement() orelse return "";
    const html = el.is(Element.Html) orelse return "";
    return html.getDir();
}

fn setDir(self: *Document, value: []const u8, frame: *Frame) !void {
    const el = self.getDocumentElement() orelse return;
    const html = el.is(Element.Html) orelse return;
    try html.asElement().setAttributeSafe(comptime .wrap("dir"), .wrap(value), frame);
}

fn getAll(self: *Document, frame: *Frame) !*collections.HTMLAllCollection {
    return frame._factory.create(collections.HTMLAllCollection.init(self.asNode(), frame));
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
    const trimmed = std.mem.trimStart(u8, html, &std.ascii.whitespace);
    return std.ascii.startsWithIgnoreCase(trimmed, "<!DOCTYPE") or
        std.ascii.startsWithIgnoreCase(trimmed, "<html");
}

pub fn write(self: *Document, text: js.Variadic([]const u8), frame: *Frame) !void {
    return self.writeInternal(text.values, false, frame);
}

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#dom-document-writeln
// `writeln(...text)` runs the document write steps with `text` followed by a
// U+000A LINE FEED character.
fn writeln(self: *Document, text: js.Variadic([]const u8), frame: *Frame) !void {
    return self.writeInternal(text.values, true, frame);
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

    if (self._active_parser_aborted or self._navigated_away) return;

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
    const fragment = try Node.DocumentFragment.init(self, frame);
    const fragment_node = fragment.asNode();

    const previous_parse_mode = frame._parse_mode;
    frame._parse_mode = .document_write;
    defer frame._parse_mode = previous_parse_mode;

    const arena = try frame.getArena(.medium, "Document.write");
    defer arena.release();

    var parser = Parser.init(arena.allocator(), fragment_node, frame, .{ .allow_declarative_shadow = true });
    parser.parseFragment(html);

    // Extract children from wrapper HTML element (html5ever wraps fragments)
    // https://github.com/servo/html5ever/issues/583
    const first = fragment_node.firstChild() orelse return;

    // Collect all children to insert (to avoid iterator invalidation)
    var children_to_insert: std.ArrayList(*Node) = .empty;

    var it = if (first.is(Element.Html.Html) == null) fragment_node.childrenIterator() else first.childrenIterator();
    while (it.next()) |child| {
        try children_to_insert.append(arena.allocator(), child);
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
    self._write_insertion_point = children_to_insert.last().?;
}

pub fn open(self: *Document, call_frame: *Frame) !*Document {
    const frame = self._frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (self._active_parser_aborted or self._navigated_away or frame._load_state == .parsing) {
        return self;
    }

    if (self._script_created_parser != null) {
        return self;
    }

    if (self._iframe_load_in_progress) {
        self._mute_iframe_load = true;
    }

    // If we aren't parsing, then open clears the document.
    const doc_node = self.asNode();

    {
        // Erase all event listeners and handlers of the document
        try frame._event_manager.removeShadowIncludingDescendants(call_frame.local_arena, doc_node);
        if (frame.document == self) {
            frame.page.event_listeners.removeTarget(frame.window.asEventTarget());
        }
    }

    {
        // Remove all children from document
        var it = doc_node.childrenIterator();
        while (it.next()) |child| {
            frame.removeNode(doc_node, child, .{ .reconnect_to = null });
        }
    }

    // reset the document
    self._ids.clear(frame.page_arena);
    self.setActiveElement(null, frame);
    self._open_popovers = .empty;
    self._modal_dialogs = .empty;
    self._style_sheets = null;
    self._implementation = null;
    self._ready_state = .loading;
    // open() cancels an ongoing navigation; the aborted document's load is
    // gone for good, as in Chrome.
    frame.cancelQueuedNavigation();

    if (std.mem.findScalar(*Document, frame._script_created_parser_docs.items, self) == null) {
        // have the page track this document (if it isn't already)
        // so that, on shutdown, it can close the parser if needed.
        try frame._script_created_parser_docs.append(frame.page_arena, self);
    }
    self._script_created_parser = Parser.Streaming.init(frame.page_arena, doc_node, frame, .{ .allow_declarative_shadow = true });
    // on start() failure the internal `handle` isn't yet create. So we can't
    // call done() and we don't want any subsequent cleanup to call done().
    errdefer self._script_created_parser = null;
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
    // Dropped before the load steps below: a load handler can write() again,
    // which must open a fresh parser rather than feed this finished one.
    {
        defer self._script_created_parser = null;
        try self._script_created_parser.?.done();
    }

    // The write'd markup is fully parsed; run any deferred scripts it produced
    // (e.g. inline modules) before firing the load event. This frame's initial
    // parse may never have set static_scripts_done (e.g. a freshly-loaded
    // iframe written into via document.write), so we can't rely on it.
    frame._script_manager.base.scriptCreatedParseDone();

    frame.scriptCreatedParserDone();
}

fn getFirstElementChild(self: *Document) ?*Element {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
    }
    return null;
}

fn getLastElementChild(self: *Document) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
        maybe_child = child.previousSibling();
    }
    return null;
}

fn getChildElementCount(self: *Document) u32 {
    var i: u32 = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element) != null) {
            i += 1;
        }
    }
    return i;
}

fn getAdoptedStyleSheets(self: *Document, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

fn getFullscreenElement(_: *const Document) ?*Element {
    // see Element.requestFullscreen, nothing is ever fullscreen
    return null;
}

fn exitFullscreen(_: *Document, frame: *Frame) js.Promise {
    return frame.js.local.?.rejectPromise(.{ .type_error = "Document not in fullscreen" });
}

// See frame/exec_command.zig. A null value is "" rather than "null".
fn execCommand(self: *Document, command: []const u8, _: ?bool, value: ?[]const u8) !bool {
    return exec_command.exec(self, command, value orelse "");
}

fn queryCommandSupported(self: *const Document, command: []const u8) bool {
    return exec_command.isSupported(self, command);
}

fn queryCommandEnabled(self: *Document, command: []const u8) bool {
    return exec_command.isEnabled(self, command);
}

// No supported command has a state or value yet.
fn queryCommandState(_: *const Document, _: []const u8) bool {
    return false;
}

fn queryCommandValue(_: *const Document, _: []const u8) []const u8 {
    return "";
}

pub fn hasFocus(self: *Document) bool {
    var top = self._frame orelse return false;
    while (top.parent) |parent| {
        top = parent;
    }

    var candidate = top;
    while (true) {
        if (candidate.document == self) {
            return true;
        }
        const active = candidate.document._active_element orelse return false;
        const iframe = active.is(Element.Html.IFrame) orelse return false;
        const window = iframe._window orelse return false;
        candidate = window._frame;
    }
}

fn setAdoptedStyleSheets(self: *Document, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

// Validates that nodes can be inserted into a Document, respecting Document constraints:
// - At most one Element child
// - At most one DocumentType child
// - No Document, Attribute, or Text nodes
// - Only Element, DocumentType, Comment, and ProcessingInstruction are allowed
fn validateDocumentNodes(self: *Document, nodes: []const Node.NodeOrText) !void {
    const parent = self.asNode();

    var has_element = false;
    var has_doctype = false;
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        if (child._type == .element) {
            has_element = true;
        } else if (child._type == .document_type) {
            has_doctype = true;
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
                            .cdata => switch (frag_child.subtype(Node.CData)._type) {
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
                        .cdata => switch (child.subtype(Node.CData)._type) {
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

fn isValidElementLocalName(name: []const u8) bool {
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

fn isValidNamespacePrefix(prefix: []const u8) bool {
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

fn isValidAttributeLocalName(name: []const u8) bool {
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

const ValidatedName = struct {
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
    if (std.mem.findScalar(u8, qualified_name, ':')) |colon| {
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
    if (comptime lp.IS_DEBUG) {
        // should only be called on an empty document
        std.debug.assert(self.asNode()._first_child == null);
    }

    const html = try Frame.node_factory.createElementNS(self, .html, "html", null);
    const head = try Frame.node_factory.createElementNS(self, .html, "head", null);
    const body = try Frame.node_factory.createElementNS(self, .html, "body", null);
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
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*Document {
        return frame._factory.genericDocument(.{ .url = "about:blank", .charset = "UTF-8" });
    }

    pub const parseHTML = bridge.function(_parseHTML, .{ .static = true });
    fn _parseHTML(html: []const u8, options: ?Sanitizer.Options, frame: *Frame) !*Document {
        return Sanitizer.parseHTML(html, options, true, frame);
    }

    pub const parseHTMLUnsafe = bridge.function(_parseHTMLUnsafe, .{ .static = true });
    fn _parseHTMLUnsafe(html: []const u8, options: ?Sanitizer.Options, frame: *Frame) !*Document {
        return Sanitizer.parseHTML(html, options, false, frame);
    }

    // GlobalEventHandlers and DocumentAndElementEventHandlers: the same on*
    // set as HTMLElement.
    pub const onabort = EventTarget.handlerAccessor(Document, "abort");
    pub const onanimationcancel = EventTarget.handlerAccessor(Document, "animationcancel");
    pub const onanimationend = EventTarget.handlerAccessor(Document, "animationend");
    pub const onanimationiteration = EventTarget.handlerAccessor(Document, "animationiteration");
    pub const onanimationstart = EventTarget.handlerAccessor(Document, "animationstart");
    pub const onauxclick = EventTarget.handlerAccessor(Document, "auxclick");
    pub const onbeforeinput = EventTarget.handlerAccessor(Document, "beforeinput");
    pub const onbeforematch = EventTarget.handlerAccessor(Document, "beforematch");
    pub const onbeforetoggle = EventTarget.handlerAccessor(Document, "beforetoggle");
    pub const onblur = EventTarget.handlerAccessor(Document, "blur");
    pub const oncancel = EventTarget.handlerAccessor(Document, "cancel");
    pub const oncanplay = EventTarget.handlerAccessor(Document, "canplay");
    pub const oncanplaythrough = EventTarget.handlerAccessor(Document, "canplaythrough");
    pub const onchange = EventTarget.handlerAccessor(Document, "change");
    pub const onclick = EventTarget.handlerAccessor(Document, "click");
    pub const onclose = EventTarget.handlerAccessor(Document, "close");
    pub const oncommand = EventTarget.handlerAccessor(Document, "command");
    pub const oncontentvisibilityautostatechange = EventTarget.handlerAccessor(Document, "contentvisibilityautostatechange");
    pub const oncontextlost = EventTarget.handlerAccessor(Document, "contextlost");
    pub const oncontextmenu = EventTarget.handlerAccessor(Document, "contextmenu");
    pub const oncontextrestored = EventTarget.handlerAccessor(Document, "contextrestored");
    pub const oncopy = EventTarget.handlerAccessor(Document, "copy");
    pub const oncuechange = EventTarget.handlerAccessor(Document, "cuechange");
    pub const oncut = EventTarget.handlerAccessor(Document, "cut");
    pub const ondblclick = EventTarget.handlerAccessor(Document, "dblclick");
    pub const ondrag = EventTarget.handlerAccessor(Document, "drag");
    pub const ondragend = EventTarget.handlerAccessor(Document, "dragend");
    pub const ondragenter = EventTarget.handlerAccessor(Document, "dragenter");
    pub const ondragleave = EventTarget.handlerAccessor(Document, "dragleave");
    pub const ondragover = EventTarget.handlerAccessor(Document, "dragover");
    pub const ondragstart = EventTarget.handlerAccessor(Document, "dragstart");
    pub const ondrop = EventTarget.handlerAccessor(Document, "drop");
    pub const ondurationchange = EventTarget.handlerAccessor(Document, "durationchange");
    pub const onemptied = EventTarget.handlerAccessor(Document, "emptied");
    pub const onended = EventTarget.handlerAccessor(Document, "ended");
    pub const onerror = EventTarget.handlerAccessor(Document, "error");
    pub const onfocus = EventTarget.handlerAccessor(Document, "focus");
    pub const onformdata = EventTarget.handlerAccessor(Document, "formdata");
    pub const onfullscreenchange = EventTarget.handlerAccessor(Document, "fullscreenchange");
    pub const onfullscreenerror = EventTarget.handlerAccessor(Document, "fullscreenerror");
    pub const ongotpointercapture = EventTarget.handlerAccessor(Document, "gotpointercapture");
    pub const oninput = EventTarget.handlerAccessor(Document, "input");
    pub const oninvalid = EventTarget.handlerAccessor(Document, "invalid");
    pub const onkeydown = EventTarget.handlerAccessor(Document, "keydown");
    pub const onkeypress = EventTarget.handlerAccessor(Document, "keypress");
    pub const onkeyup = EventTarget.handlerAccessor(Document, "keyup");
    pub const onload = EventTarget.handlerAccessor(Document, "load");
    pub const onloadeddata = EventTarget.handlerAccessor(Document, "loadeddata");
    pub const onloadedmetadata = EventTarget.handlerAccessor(Document, "loadedmetadata");
    pub const onloadstart = EventTarget.handlerAccessor(Document, "loadstart");
    pub const onlostpointercapture = EventTarget.handlerAccessor(Document, "lostpointercapture");
    pub const onmousedown = EventTarget.handlerAccessor(Document, "mousedown");
    pub const onmouseenter = EventTarget.handlerAccessor(Document, "mouseenter");
    pub const onmouseleave = EventTarget.handlerAccessor(Document, "mouseleave");
    pub const onmousemove = EventTarget.handlerAccessor(Document, "mousemove");
    pub const onmouseout = EventTarget.handlerAccessor(Document, "mouseout");
    pub const onmouseover = EventTarget.handlerAccessor(Document, "mouseover");
    pub const onmouseup = EventTarget.handlerAccessor(Document, "mouseup");
    pub const onpaste = EventTarget.handlerAccessor(Document, "paste");
    pub const onpause = EventTarget.handlerAccessor(Document, "pause");
    pub const onplay = EventTarget.handlerAccessor(Document, "play");
    pub const onplaying = EventTarget.handlerAccessor(Document, "playing");
    pub const onpointercancel = EventTarget.handlerAccessor(Document, "pointercancel");
    pub const onpointerdown = EventTarget.handlerAccessor(Document, "pointerdown");
    pub const onpointerenter = EventTarget.handlerAccessor(Document, "pointerenter");
    pub const onpointerleave = EventTarget.handlerAccessor(Document, "pointerleave");
    pub const onpointermove = EventTarget.handlerAccessor(Document, "pointermove");
    pub const onpointerout = EventTarget.handlerAccessor(Document, "pointerout");
    pub const onpointerover = EventTarget.handlerAccessor(Document, "pointerover");
    pub const onpointerrawupdate = EventTarget.handlerAccessor(Document, "pointerrawupdate");
    pub const onpointerup = EventTarget.handlerAccessor(Document, "pointerup");
    pub const onprogress = EventTarget.handlerAccessor(Document, "progress");
    pub const onratechange = EventTarget.handlerAccessor(Document, "ratechange");
    pub const onreset = EventTarget.handlerAccessor(Document, "reset");
    pub const onresize = EventTarget.handlerAccessor(Document, "resize");
    pub const onscroll = EventTarget.handlerAccessor(Document, "scroll");
    pub const onscrollend = EventTarget.handlerAccessor(Document, "scrollend");
    pub const onsecuritypolicyviolation = EventTarget.handlerAccessor(Document, "securitypolicyviolation");
    pub const onseeked = EventTarget.handlerAccessor(Document, "seeked");
    pub const onseeking = EventTarget.handlerAccessor(Document, "seeking");
    pub const onselect = EventTarget.handlerAccessor(Document, "select");
    pub const onselectionchange = EventTarget.handlerAccessor(Document, "selectionchange");
    pub const onselectstart = EventTarget.handlerAccessor(Document, "selectstart");
    pub const onslotchange = EventTarget.handlerAccessor(Document, "slotchange");
    pub const onstalled = EventTarget.handlerAccessor(Document, "stalled");
    pub const onsubmit = EventTarget.handlerAccessor(Document, "submit");
    pub const onsuspend = EventTarget.handlerAccessor(Document, "suspend");
    pub const ontimeupdate = EventTarget.handlerAccessor(Document, "timeupdate");
    pub const ontoggle = EventTarget.handlerAccessor(Document, "toggle");
    pub const ontransitioncancel = EventTarget.handlerAccessor(Document, "transitioncancel");
    pub const ontransitionend = EventTarget.handlerAccessor(Document, "transitionend");
    pub const ontransitionrun = EventTarget.handlerAccessor(Document, "transitionrun");
    pub const ontransitionstart = EventTarget.handlerAccessor(Document, "transitionstart");
    pub const onvolumechange = EventTarget.handlerAccessor(Document, "volumechange");
    pub const onwaiting = EventTarget.handlerAccessor(Document, "waiting");
    pub const onwheel = EventTarget.handlerAccessor(Document, "wheel");
    pub const onreadystatechange = EventTarget.handlerAccessor(Document, "readystatechange");
    pub const onvisibilitychange = EventTarget.handlerAccessor(Document, "visibilitychange");
    pub const URL = bridge.accessor(Document.getURL, null, .{});
    pub const location = bridge.accessor(Document.getLocation, Document.setLocation, .{ .unforgeable = true, .deletable = false });
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
    fn _getElementById(self: *Document, value_: ?js.Value) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) {
            return self.getElementById("null");
        }
        if (value.isUndefined()) {
            return self.getElementById("undefined");
        }
        return self.getElementById(try value.toZig([]const u8));
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
    pub const dir = bridge.accessor(Document.getDir, Document.setDir, .{ .ce_reactions = true });
    pub const fgColor = bodyColor("text");
    pub const linkColor = bodyColor("link");
    pub const vlinkColor = bodyColor("vlink");
    pub const alinkColor = bodyColor("alink");
    pub const bgColor = bodyColor("bgcolor");

    // Legacy [LegacyNullToEmptyString] attributes that reflect an attribute of
    // the body element ("" without one).
    fn bodyColor(comptime attr: []const u8) js.bridge.Accessor {
        const R = struct {
            fn get(self: *Document) []const u8 {
                const b = self.getBody() orelse return "";
                if (b.is(Element.Html.Body) == null) return "";
                return b.asElement().getAttributeSafe(comptime .wrap(attr)) orelse "";
            }
            fn set(self: *Document, value: js.Value, frame: *Frame) !void {
                const b = self.getBody() orelse return;
                if (b.is(Element.Html.Body) == null) return;
                const str = if (value.isNull()) "" else try value.toStringSlice();
                try b.asElement().setAttributeSafe(comptime .wrap(attr), .wrap(str), frame);
            }
        };
        return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
    }
    pub const head = bridge.accessor(Document.getHead, null, .{});
    pub const body = bridge.accessor(Document.getBody, Document.setBody, .{ .ce_reactions = true });
    pub const title = bridge.accessor(Document.getTitle, Document.setTitle, .{ .ce_reactions = true });
    pub const images = bridge.accessor(Document.getImages, null, .{});
    pub const scripts = bridge.accessor(Document.getScripts, null, .{});
    pub const links = bridge.accessor(Document.getLinks, null, .{});
    pub const anchors = bridge.accessor(Document.getAnchors, null, .{});
    pub const forms = bridge.accessor(Document.getForms, null, .{});
    pub const embeds = bridge.accessor(Document.getEmbeds, null, .{});
    pub const applets = bridge.accessor(Document.getApplets, null, .{});
    pub const plugins = bridge.accessor(Document.getEmbeds, null, .{});
    pub const currentScript = bridge.accessor(Document.getCurrentScript, null, .{});
    pub const all = bridge.accessor(Document.getAll, null, .{});

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
            if (frame.window._closed) {
                return null;
            }
            return frame.window;
        }
    }.defaultView, null, .{});
    pub const hasFocus = bridge.function(Document.hasFocus, .{});
    pub const fullscreenEnabled = bridge.property(false, .{ .template = false, .readonly = true });
    pub const fullscreen = bridge.property(false, .{ .template = false, .readonly = true });
    pub const fullscreenElement = bridge.accessor(Document.getFullscreenElement, null, .{});
    pub const exitFullscreen = bridge.function(Document.exitFullscreen, .{});
    pub const execCommand = bridge.function(Document.execCommand, .{});
    pub const queryCommandEnabled = bridge.function(Document.queryCommandEnabled, .{});
    pub const queryCommandIndeterm = bridge.function(Document.queryCommandState, .{});
    pub const queryCommandState = bridge.function(Document.queryCommandState, .{});
    pub const queryCommandSupported = bridge.function(Document.queryCommandSupported, .{});
    pub const queryCommandValue = bridge.function(Document.queryCommandValue, .{});

    pub const prerendering = bridge.property(false, .{ .template = false });
    pub const characterSet = bridge.accessor(Document.getCharset, null, .{});
    pub const charset = bridge.accessor(Document.getCharset, null, .{});
    pub const inputEncoding = bridge.accessor(Document.getCharset, null, .{});
    pub const compatMode = bridge.accessor(Document.getCompatMode, null, .{});
    pub const designMode = bridge.accessor(Document.getDesignMode, Document.setDesignMode, .{});
    pub const lastModified = bridge.accessor(Document.getLastModified, null, .{});
    pub const referrer = bridge.accessor(Document.getReferrer, null, .{});
};

const testing = @import("../../testing.zig");
const HttpClient = @import("../../network/HttpClient.zig");

test "WebApi: Document" {
    try testing.htmlRunner("document", .{});
}

test "WebApi: Document.evaluate" {
    try testing.htmlRunner("xpath/document_evaluate.html", .{});
}

test "Document: cookie access from a cross-site frame" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    const doc = frame.document;
    const jar = &frame._session.cookie_jar;
    defer jar.clearRetainingCapacity();

    // victim.example embedded by attacker.example: the ancestor chain is
    // cross-site, so the frame has no site for cookies.
    var top_url: [:0]const u8 = "https://attacker.example/";
    var top: HttpClient.Owner = undefined;
    top.url = &top_url;
    top.parent = null;
    frame.url = "https://victim.example/inner";
    frame._http_owner.parent = &top;
    defer frame._http_owner.parent = null;

    try jar.populateFromResponse("https://victim.example/", "strict=1; SameSite=Strict");
    try jar.populateFromResponse("https://victim.example/", "lax=2; SameSite=Lax");
    try jar.populateFromResponse("https://victim.example/", "default=3");
    try jar.populateFromResponse("https://victim.example/", "none=4; SameSite=None; Secure");

    // Reads: only SameSite=None is visible from a cross-site context. Lax
    // gets no navigation exception for script access.
    try testing.expectEqual("none=4", try doc.getCookie(frame));

    // Writes: SameSite=None is stored, everything else (including the Lax
    // default for an unspecified attribute) is silently dropped.
    _ = try doc.setCookie("set_strict=5; SameSite=Strict", frame);
    _ = try doc.setCookie("set_lax=6; SameSite=Lax", frame);
    _ = try doc.setCookie("set_default=7", frame);
    _ = try doc.setCookie("set_none=8; SameSite=None; Secure", frame);
    try testing.expectEqual("none=4; set_none=8", try doc.getCookie(frame));

    // The same jar seen from a same-site chain: everything applies, and the
    // dropped writes really were dropped rather than hidden.
    top_url = "https://victim.example/";
    try testing.expectEqual("strict=1; lax=2; default=3; none=4; set_none=8", try doc.getCookie(frame));
    _ = try doc.setCookie("set_strict=5; SameSite=Strict", frame);
    _ = try doc.setCookie("set_default=7", frame);
    try testing.expectEqual("strict=1; lax=2; default=3; none=4; set_none=8; set_strict=5; set_default=7", try doc.getCookie(frame));

    // Back in the cross-site context, the newly written cookies obey the
    // same visibility rules.
    top_url = "https://attacker.example/";
    try testing.expectEqual("none=4; set_none=8", try doc.getCookie(frame));
}

test "Document: a non-secure document can't set or overwrite a Secure cookie" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    const doc = frame.document;
    const jar = &frame._session.cookie_jar;
    defer jar.clearRetainingCapacity();

    frame.url = "http://victim.example/";
    _ = try doc.setCookie("s=1; Secure", frame);
    try testing.expectEqual(0, jar.len);

    try jar.populateFromResponse("https://victim.example/", "s=1; Secure");
    _ = try doc.setCookie("s=2", frame);
    var it = jar.iterator();
    try testing.expectEqual("1", it.next().?.value);
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
