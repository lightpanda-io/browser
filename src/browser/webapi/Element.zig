// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const dump = @import("../dump.zig");
const Frame = @import("../Frame.zig");
const Factory = @import("../Factory.zig");
const StyleManager = @import("../StyleManager.zig");

const CSS = @import("CSS.zig");
const Node = @import("Node.zig");
const ShadowRoot = @import("ShadowRoot.zig");
const EventTarget = @import("EventTarget.zig");
const collections = @import("collections.zig");

const Selector = @import("selector/Selector.zig");
const Animation = @import("animation/Animation.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");

const slotting = @import("element/slotting.zig");
const DOMStringMap = @import("element/DOMStringMap.zig");

pub const DOMRect = @import("DOMRect.zig");
pub const Svg = @import("element/Svg.zig");
pub const Html = @import("element/Html.zig");
pub const Attribute = @import("element/Attribute.zig");
pub const Reflect = @import("element/reflection.zig").Reflect;

const log = lp.log;
const String = lp.String;

const Element = @This();

pub const Proto = Node;

pub const DatasetLookup = std.AutoHashMapUnmanaged(*Element, *DOMStringMap);
pub const StyleLookup = std.AutoHashMapUnmanaged(*Element, *CSSStyleProperties);
pub const ComputedStyleLookup = std.AutoHashMapUnmanaged(ComputedStyleKey, *CSSStyleProperties);

pub const ComputedStyleKey = struct {
    element: *Element,
    pseudo: PseudoElement,
};

pub const PseudoElement = enum {
    none,
    before,
    after,
    other,

    pub fn parse(pseudo: []const u8) PseudoElement {
        if (pseudo.len == 0 or pseudo[0] != ':') {
            return .none;
        }
        const name = if (std.mem.startsWith(u8, pseudo, "::")) pseudo[2..] else pseudo[1..];
        if (std.ascii.eqlIgnoreCase(name, "before")) return .before;
        if (std.ascii.eqlIgnoreCase(name, "after")) return .after;
        return .other;
    }
};

pub const ClassListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const RelListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const PartListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const ShadowRootLookup = std.AutoHashMapUnmanaged(*Element, *ShadowRoot);
pub const NamespaceUriLookup = std.AutoHashMapUnmanaged(*Element, []const u8);

pub const ScrollPosition = struct {
    x: u32 = 0,
    y: u32 = 0,
    // Throttle state for the async scroll/scrollend dispatch (mirrors
    // Window._scroll_pos.state).
    state: enum { scroll, end, done } = .done,
};
pub const ScrollPositionLookup = std.AutoHashMapUnmanaged(*Element, ScrollPosition);

pub const Namespace = enum(u8) {
    html,
    svg,
    mathml,
    xml,
    // We should keep the original value, but don't.  If this becomes important
    // consider storing it in a frame lookup, like `_element_class_lists`, rather
    // that adding a slice directly here (directly in every element).
    unknown,
    null,

    pub fn toUri(self: Namespace) ?[]const u8 {
        return switch (self) {
            .html => "http://www.w3.org/1999/xhtml",
            .svg => "http://www.w3.org/2000/svg",
            .mathml => "http://www.w3.org/1998/Math/MathML",
            .xml => "http://www.w3.org/XML/1998/namespace",
            .unknown => "http://lightpanda.io/unsupported/namespace",
            .null => null,
        };
    }

    pub fn parse(namespace_: ?[]const u8) Namespace {
        const namespace = namespace_ orelse return .null;
        if (namespace.len == 0) {
            return .null;
        }
        if (namespace.len == "http://www.w3.org/1999/xhtml".len) {
            // Common case, avoid the string comparison. Recklessly
            @branchHint(.likely);
            return .html;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/XML/1998/namespace")) {
            return .xml;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/2000/svg")) {
            return .svg;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/1998/Math/MathML")) {
            return .mathml;
        }
        return .unknown;
    }
};

pub const Flags = packed struct(u8) {
    shadow_host: bool = false,
    customized_builtin: bool = false,

    // Prevents nested clicks (which have a specific spec-compliant behavior
    // compared to other events). If this bit can be more useful for something
    // else, a stack in EventManager (for click-specifically) is an alterantive
    // approach
    click_in_progress: bool = false,

    // The element may have inline style: a materialized entry in the frame's
    // _element_styles, or a `style` attribute not yet materialized. Set once,
    // never cleared. A clear bit lets the faux layout skip both the map probe
    // and the attribute scan for the many elements that have neither.
    has_inline_style: bool = false,

    _unused: u4 = 0,
};

_type: Type,
_namespace: Namespace = .html,
// Presence hints for the frame's element-keyed side tables: a set bit means
// "maybe in the map" (the map stays the authority), a clear bit skips the
// lookup. Turns the per-element map probe in tree walks into a bit test on
// memory the walk already touches. Fits in existing struct padding.
_flags: Flags = .{},
_attributes: Attribute.List = .{},
// In debug, set so that we can check that we have a proper contiguous block
// of memory for the entire chain (and thus, simple pointer arithmetics will
// work to resolve the proto).
_proto_canary: if (lp.IS_DEBUG) *Node else void = undefined,

pub const Type = enum(u8) {
    html,
    svg,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .html => Html,
        .svg => Svg,
    };
}

pub fn subtype(self: *const Element, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, Element);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *Element, comptime T: type) ?*T {
    const type_name = @typeName(T);
    switch (self._type) {
        .html => {
            const el = self.subtype(Html);
            if (T == Html) {
                return el;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.")) {
                return el.is(T);
            }
        },
        .svg => {
            const svg = self.subtype(Svg);
            if (T == Svg) {
                return svg;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.svg.")) {
                return svg.is(T);
            }
        },
    }
    return null;
}

pub fn as(self: *Element, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Element) *Node {
    return Factory.protoOf(self);
}

pub fn asEventTarget(self: *Element) *EventTarget {
    return self.asNode().asEventTarget();
}

pub fn asConstNode(self: *const Element) *const Node {
    return Factory.protoOf(@constCast(self));
}

/// TODO: localName and prefix comparison.
pub fn isEqualNode(self: *Element, other: *Element) bool {
    const self_tag = self.getTagNameDump();
    const other_tag = other.getTagNameDump();
    // Compare namespaces and tags.
    const dirty = self._namespace != other._namespace or !std.mem.eql(u8, self_tag, other_tag);
    if (dirty) {
        return false;
    }

    if (self._attributes.eql(&other._attributes) == false) {
        return false;
    }

    return self.asNode().isEqualChildren(other.asNode());
}

pub fn getTagNameLower(self: *const Element) []const u8 {
    switch (self._type) {
        .html => {
            const he = self.subtype(Html);
            switch (he._type) {
                .custom => {
                    @branchHint(.unlikely);
                    return he.subtype(Html.Custom)._tag_name.str();
                },
                else => return switch (he._type) {
                    .anchor => "a",
                    .area => "area",
                    .base => "base",
                    .body => "body",
                    .br => "br",
                    .button => "button",
                    .canvas => "canvas",
                    .custom => he.subtype(Html.Custom)._tag_name.str(),
                    .data => "data",
                    .datalist => "datalist",
                    .details => "details",
                    .dialog => "dialog",
                    .directory => "dir",
                    .div => "div",
                    .dl => "dl",
                    .embed => "embed",
                    .fieldset => "fieldset",
                    .font => "font",
                    .frameset => "frameset",
                    .form => "form",
                    .generic => he.subtype(Html.Generic)._tag_name.str(),
                    .heading => he.subtype(Html.Heading)._tag_name.str(),
                    .head => "head",
                    .html => "html",
                    .hr => "hr",
                    .iframe => "iframe",
                    .img => "img",
                    .input => "input",
                    .label => "label",
                    .legend => "legend",
                    .li => "li",
                    .link => "link",
                    .map => "map",
                    .marquee => "marquee",
                    .media => switch (he.subtype(Html.Media)._type) {
                        .audio => "audio",
                        .video => "video",
                        .generic => "media",
                    },
                    .meta => "meta",
                    .meter => "meter",
                    .mod => he.subtype(Html.Mod)._tag_name.str(),
                    .object => "object",
                    .ol => "ol",
                    .optgroup => "optgroup",
                    .option => "option",
                    .output => "output",
                    .p => "p",
                    .picture => "picture",
                    .param => "param",
                    .pre => "pre",
                    .progress => "progress",
                    .quote => he.subtype(Html.Quote)._tag_name.str(),
                    .script => "script",
                    .select => "select",
                    .slot => "slot",
                    .source => "source",
                    .span => "span",
                    .style => "style",
                    .table => "table",
                    .table_caption => "caption",
                    .table_cell => he.subtype(Html.TableCell)._tag_name.str(),
                    .table_col => he.subtype(Html.TableCol)._tag_name.str(),
                    .table_row => "tr",
                    .table_section => he.subtype(Html.TableSection)._tag_name.str(),
                    .template => "template",
                    .textarea => "textarea",
                    .time => "time",
                    .title => "title",
                    .track => "track",
                    .ul => "ul",
                    .unknown => he.subtype(Html.Unknown)._tag_name.str(),
                },
            }
        },
        .svg => return self.subtype(Svg)._tag_name.str(),
    }
}

pub fn getTagNameSpec(self: *const Element, buf: []u8) []const u8 {
    return switch (self._type) {
        .html => blk: {
            const he = self.subtype(Html);
            break :blk switch (he._type) {
                .anchor => "A",
                .area => "AREA",
                .base => "BASE",
                .body => "BODY",
                .br => "BR",
                .button => "BUTTON",
                .canvas => "CANVAS",
                .custom => upperTagName(&he.subtype(Html.Custom)._tag_name, buf),
                .data => "DATA",
                .datalist => "DATALIST",
                .details => "DETAILS",
                .dialog => "DIALOG",
                .directory => "DIR",
                .div => "DIV",
                .dl => "DL",
                .embed => "EMBED",
                .fieldset => "FIELDSET",
                .font => "FONT",
                .frameset => "FRAMESET",
                .form => "FORM",
                .generic => upperTagName(&he.subtype(Html.Generic)._tag_name, buf),
                .heading => upperTagName(&he.subtype(Html.Heading)._tag_name, buf),
                .head => "HEAD",
                .html => "HTML",
                .hr => "HR",
                .iframe => "IFRAME",
                .img => "IMG",
                .input => "INPUT",
                .label => "LABEL",
                .legend => "LEGEND",
                .li => "LI",
                .link => "LINK",
                .map => "MAP",
                .marquee => "MARQUEE",
                .meta => "META",
                .media => switch (he.subtype(Html.Media)._type) {
                    .audio => "AUDIO",
                    .video => "VIDEO",
                    .generic => "MEDIA",
                },
                .meter => "METER",
                .mod => upperTagName(&he.subtype(Html.Mod)._tag_name, buf),
                .object => "OBJECT",
                .ol => "OL",
                .optgroup => "OPTGROUP",
                .option => "OPTION",
                .output => "OUTPUT",
                .p => "P",
                .picture => "PICTURE",
                .param => "PARAM",
                .pre => "PRE",
                .progress => "PROGRESS",
                .quote => upperTagName(&he.subtype(Html.Quote)._tag_name, buf),
                .script => "SCRIPT",
                .select => "SELECT",
                .slot => "SLOT",
                .source => "SOURCE",
                .span => "SPAN",
                .style => "STYLE",
                .table => "TABLE",
                .table_caption => "CAPTION",
                .table_cell => upperTagName(&he.subtype(Html.TableCell)._tag_name, buf),
                .table_col => upperTagName(&he.subtype(Html.TableCol)._tag_name, buf),
                .table_row => "TR",
                .table_section => upperTagName(&he.subtype(Html.TableSection)._tag_name, buf),
                .template => "TEMPLATE",
                .textarea => "TEXTAREA",
                .time => "TIME",
                .title => "TITLE",
                .track => "TRACK",
                .ul => "UL",
                .unknown => switch (self._namespace) {
                    .html => upperTagName(&he.subtype(Html.Unknown)._tag_name, buf),
                    .svg, .xml, .mathml, .unknown, .null => he.subtype(Html.Unknown)._tag_name.str(),
                },
            };
        },
        .svg => self.subtype(Svg)._tag_name.str(),
    };
}

pub fn getTagNameDump(self: *const Element) []const u8 {
    switch (self._type) {
        .html => return self.getTagNameLower(),
        .svg => return self.subtype(Svg)._tag_name.str(),
    }
}

pub fn getNamespaceURI(self: *const Element) ?[]const u8 {
    return self._namespace.toUri();
}

pub fn getNamespaceUri(self: *Element, frame: *Frame) ?[]const u8 {
    if (self._namespace != .unknown) return self._namespace.toUri();
    return frame._element_namespace_uris.get(self);
}

pub fn lookupNamespaceURIForElement(self: *Element, prefix: ?[]const u8, frame: *Frame) ?[]const u8 {
    // Hardcoded reserved prefixes
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml")) return "http://www.w3.org/XML/1998/namespace";
        if (std.mem.eql(u8, p, "xmlns")) return "http://www.w3.org/2000/xmlns/";
    }

    // Step 1: check element's own namespace/prefix
    if (self.getNamespaceUri(frame)) |ns_uri| {
        const el_prefix = self._prefix();
        const match = if (prefix == null and el_prefix == null)
            true
        else if (prefix != null and el_prefix != null)
            std.mem.eql(u8, prefix.?, el_prefix.?)
        else
            false;
        if (match) return ns_uri;
    }

    // Step 2: search xmlns attributes
    for (self._attributes.entries()) |*entry| {
        if (prefix == null) {
            if (std.mem.eql(u8, entry.name(), "xmlns")) {
                const val = entry.value();
                return if (val.len == 0) null else val;
            }
        } else {
            const name = entry.name();
            if (std.mem.startsWith(u8, name, "xmlns:")) {
                if (std.mem.eql(u8, name["xmlns:".len..], prefix.?)) {
                    const val = entry.value();
                    return if (val.len == 0) null else val;
                }
            }
        }
    }

    // Step 3: recurse to parent element
    const parent = self.asNode().parentElement() orelse return null;
    return parent.lookupNamespaceURIForElement(prefix, frame);
}

// Locate a namespace prefix: the inverse of lookupNamespaceURIForElement.
// Given a namespace URI, find the prefix that declares it.
pub fn lookupPrefixForElement(self: *Element, namespace: []const u8, frame: *Frame) ?[]const u8 {
    // Step 1: element's own namespace/prefix
    if (self.getNamespaceUri(frame)) |ns_uri| {
        if (self._prefix()) |el_prefix| {
            if (std.mem.eql(u8, ns_uri, namespace)) {
                return el_prefix;
            }
        }
    }

    // Step 2: search xmlns: attribute declarations for one whose value is the namespace
    for (self._attributes.entries()) |*entry| {
        const name = entry.name();
        if (std.mem.startsWith(u8, name, "xmlns:") and std.mem.eql(u8, entry.value(), namespace)) {
            return name["xmlns:".len..];
        }
    }

    // Step 3: recurse to parent element
    const parent = self.asNode().parentElement() orelse return null;
    return parent.lookupPrefixForElement(namespace, frame);
}

fn _prefix(self: *const Element) ?[]const u8 {
    const name = self.getTagNameLower();
    if (std.mem.indexOfPos(u8, name, 0, ":")) |pos| {
        return name[0..pos];
    }
    return null;
}

pub fn getLocalName(self: *Element) []const u8 {
    const name = self.getTagNameLower();
    if (std.mem.indexOfPos(u8, name, 0, ":")) |pos| {
        return name[pos + 1 ..];
    }

    return name;
}

// Wrapper methods that delegate to Html implementations
pub fn getInnerText(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.getInnerText(writer, frame);
}

pub fn setInnerText(self: *Element, text: []const u8, frame: *Frame) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.setInnerText(text, frame);
}

pub fn insertAdjacentHTML(
    self: *Element,
    position: []const u8,
    html_or_xml: []const u8,
    frame: *Frame,
) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.insertAdjacentHTML(position, html_or_xml, frame);
}

pub fn getOuterHTML(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    return dump.deep(self.asNode(), .{ .shadow = .skip }, writer, frame);
}

pub fn setOuterHTML(self: *Element, html: []const u8, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node._parent orelse return;

    // The parent of a documentElement is the Document, which cannot be modified.
    if (parent._type == .document) {
        return error.NoModificationAllowed;
    }

    frame.domChanged();

    // Observers of the parent must see a single mutation record replacing
    // this node with the parsed nodes.
    const notify = Frame.observers.hasMutationObservers(frame);
    var added: std.ArrayList(*Node) = .empty;

    var fragment: ?*Node = null;
    if (html.len > 0) {
        const frag = (try Node.DocumentFragment.init(frame)).asNode();
        // The parent is the parse context (a fragment parent means body).
        try Frame.parse.fragment(frame, frag, html, .{ .context = parent.is(Element) });
        fragment = frag;
    }

    // Parsing (and each insertion below) can synchronously run a custom
    // element constructor that mutates the live tree; per the spec's replace
    // step, a node that is no longer our parent's child cannot be replaced.
    if (node._parent != parent) {
        return error.NotFound;
    }

    // Captured after the parse: a constructor may have reshuffled siblings.
    const previous_sibling = node.previousSibling();
    const next_sibling = node.nextSibling();

    if (fragment) |frag| {
        var it = frag.childrenIterator();
        while (it.next()) |child| {
            if (node._parent != parent) {
                return error.NotFound;
            }
            if (notify) {
                try added.append(frame.call_arena, child);
            }
            frame.removeNode(frag, child, .{ .reconnect_to = parent, .notify_observers = false });
            try frame.insertNodeRelative(parent, child, .{ .before = node }, .{ .notify_observers = false });
        }
    }

    if (node._parent != parent) {
        return error.NotFound;
    }
    frame.removeNode(parent, node, .{ .reconnect_to = null, .notify_observers = false });

    if (notify) {
        const removed = [_]*Node{node};
        Frame.observers.notifyChildListChange(frame, parent, added.items, &removed, previous_sibling, next_sibling);
    }
}

pub fn getInnerHTML(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    return dump.children(self.asNode(), .{ .shadow = .skip }, writer, frame);
}

pub fn getHTML(self: *Element, opts: dump.Opts.Shadow.Declarative, writer: *std.Io.Writer, frame: *Frame) !void {
    return dump.getHTML(self.asNode(), opts, writer, frame);
}

pub fn setInnerHTML(self: *Element, html: []const u8, frame: *Frame) !void {
    const parent = self.asNode();
    return parent.setHTML(html, .{}, frame);
}

/// allows declarative shadow dom
pub fn setHTMLUnsafe(self: *Element, html: []const u8, frame: *Frame) !void {
    const parent = self.asNode();
    return parent.setHTML(html, .{ .allow_declarative_shadow = true }, frame);
}

pub fn getId(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("id")) orelse "";
}

pub fn setId(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("id"), .wrap(value), frame);
}

pub fn getSlot(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("slot")) orelse "";
}

pub fn setSlot(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("slot"), .wrap(value), frame);
}

pub fn getDir(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("dir")) orelse "";
}

pub fn setDir(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("dir"), .wrap(value), frame);
}

pub fn getClassName(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("class")) orelse "";
}

pub fn setClassName(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("class"), .wrap(value), frame);
}

/// DANGER: Invalidated by mutation of the attribute list.
pub fn attributeEntries(self: *const Element) []const Attribute.List.Entry {
    return self._attributes.entries();
}

pub fn getAttribute(self: *const Element, name: String, frame: *Frame) !?String {
    return self._attributes.get(name, frame);
}

pub fn getAttributeNS(
    self: *const Element,
    namespace_: ?[]const u8,
    local_name: String,
    frame: *Frame,
) !?String {
    if (namespace_) |namespace| {
        // we don't really support namespaces, but if the namespace has a fixed
        // prefix, we can try to fetch the attribute with it
        if (try prefixedAttributeName(namespace, local_name.str(), frame)) |prefixed| {
            if (try self.getAttribute(.wrap(prefixed), frame)) |value| {
                return value;
            }
        }
    }
    return self.getAttribute(local_name, frame);
}

fn prefixedAttributeName(namespace: []const u8, local_name: []const u8, frame: *Frame) !?[]const u8 {
    const prefix = blk: {
        if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xlink")) {
            break :blk "xlink";
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/XML/1998/namespace")) {
            break :blk "xml";
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/2000/xmlns/")) {
            break :blk "xmlns";
        }
        return null;
    };
    return try std.fmt.allocPrint(frame.local_arena, "{s}:{s}", .{ prefix, local_name });
}

pub fn getAttributeSafe(self: *const Element, name: String) ?[]const u8 {
    return self._attributes.getSafe(name);
}

pub fn hasAttribute(self: *const Element, name: String, frame: *Frame) !bool {
    const value = try self._attributes.get(name, frame);
    return value != null;
}

pub fn hasAttributeNS(
    self: *const Element,
    namespace_: ?[]const u8,
    local_name: String,
    frame: *Frame,
) !bool {
    return try self.getAttributeNS(namespace_, local_name, frame) != null;
}

pub fn hasAttributeSafe(self: *const Element, name: String) bool {
    return self._attributes.hasSafe(name);
}

// Per HTML "concept-fe-disabled", only listed elements participate in the
// disabled concept. Anything else (e.g. <div disabled>) has no disabled
// state and never matches :disabled / :enabled.
pub fn hasDisabledConcept(self: *const Element) bool {
    return switch (self.getTag()) {
        .button, .input, .select, .textarea, .optgroup, .option, .fieldset => true,
        else => false,
    };
}

pub fn isDisabled(self: *const Element) bool {
    if (!self.hasDisabledConcept()) {
        return false;
    }

    if (self.getAttributeSafe(comptime .wrap("disabled")) != null) {
        return true;
    }

    // <option> takes a different inheritance path: per HTML
    // "concept-option-disabled" an option is disabled when its parent is an
    // <optgroup disabled>. It does NOT inherit from <select disabled> or
    // an ancestor <fieldset disabled>.
    if (self.getTag() == .option) {
        if (self.asConstNode()._parent) |parent_node| {
            if (parent_node.is(Element)) |parent_el| {
                if (parent_el.getTag() == .optgroup and
                    parent_el.getAttributeSafe(comptime .wrap("disabled")) != null)
                {
                    return true;
                }
            }
        }
        return false;
    }

    const element_node = self.asConstNode();
    var current: ?*Node = element_node._parent;
    while (current) |node| {
        current = node._parent;
        const ancestor = node.is(Element) orelse continue;

        if (ancestor.getTag() == .fieldset and ancestor.getAttributeSafe(comptime .wrap("disabled")) != null) {
            var child = ancestor.firstElementChild();
            while (child) |c| {
                if (c.getTag() == .legend) {
                    if (c.asNode().contains(element_node)) return false;
                    break;
                }
                child = c.nextElementSibling();
            }
            return true;
        }
    }
    return false;
}

pub fn hasAttributes(self: *const Element) bool {
    return self._attributes.isEmpty() == false;
}

pub fn getAttributeNode(self: *Element, name: String, frame: *Frame) !?*Attribute {
    return self._attributes.getAttribute(name, self, frame);
}

pub fn setAttribute(self: *Element, name: String, value: String, frame: *Frame) !void {
    try Attribute.validateAttributeName(name);
    _ = try self._attributes.put(name, value, self, frame);
}

pub fn setAttributeNS(
    self: *Element,
    namespace_: ?[]const u8,
    qualified_name: []const u8,
    value: String,
    frame: *Frame,
) !void {
    const local_start = if (std.mem.indexOfScalarPos(u8, qualified_name, 0, ':')) |idx| blk: {
        if (idx == 0 or idx == qualified_name.len - 1) {
            // cannot be at the start or end of the qname
            return error.InvalidCharacterError;
        }
        if (std.mem.indexOfScalarPos(u8, qualified_name, idx + 1, ':') != null) {
            // and can only have one
            return error.InvalidCharacterError;
        }
        break :blk idx + 1;
    } else 0;

    const attr_name = if (namespace_ != null) qualified_name else qualified_name[local_start..];
    return self.setAttribute(.wrap(attr_name), value, frame);
}

pub fn setAttributeSafe(self: *Element, name: String, value: String, frame: *Frame) !void {
    _ = try self._attributes.putSafe(name, value, self, frame);
}

pub fn getShadowRoot(self: *Element, frame: *Frame) ?*ShadowRoot {
    const shadow_root = self.hostedShadowRoot(frame) orelse return null;
    if (shadow_root._mode == .closed) return null;
    return shadow_root;
}

pub fn getAssignedSlot(self: *Element, frame: *Frame) ?*Html.Slot {
    // Hidden by a closed shadow tree
    return slotting.findSlot(self.asNode(), true, frame);
}

// Whether this element may host a shadow root
fn isValidShadowHost(self: *const Element) bool {
    if (self._namespace != .html) {
        return false;
    }

    return switch (self.getTag()) {
        .article, .aside, .blockquote, .body, .div, .footer, .header, .main, .nav, .p, .section, .span, .h1, .h2, .h3, .h4, .h5, .h6, .custom => true,
        else => false,
    };
}

pub fn attachShadow(self: *Element, opts: ShadowRoot.AttachOptions, frame: *Frame) !*ShadowRoot {
    if (!self.isValidShadowHost()) {
        return error.NotSupported;
    }

    // A custom element whose definition lists "shadow" in disabledFeatures
    // cannot host a shadow root (imperative or declarative).
    if (self.is(Html.Custom)) |custom| {
        if (frame.window._custom_elements._definitions.get(custom._tag_name.str())) |def| {
            if (def.disable_shadow) {
                return error.NotSupported;
            }
        }
    }

    if (self.hostedShadowRoot(frame)) |existing| {
        // Imperative attachShadow over a declarative shadow root with a matching
        // mode empties it and returns the same root. The parser
        // (opts.declarative) never replaces an existing root.
        if (opts.declarative or !existing._declarative or existing._mode != opts.mode) {
            return error.NotSupported;
        }
        try existing.asNode().replaceChildren(&.{}, frame);
        existing._declarative = false;
        return existing;
    }

    const shadow_root = try ShadowRoot.init(self, opts, frame);
    try frame._element_shadow_roots.put(frame.arena, self, shadow_root);
    self._flags.shadow_host = true;
    return shadow_root;
}

// The shadow root this element hosts, closed ones included (the JS-facing
// getShadowRoot filters those). The flag check skips the map probe for the
// overwhelming majority of elements, which host nothing.
pub fn hostedShadowRoot(self: *Element, frame: *const Frame) ?*ShadowRoot {
    if (!self._flags.shadow_host) {
        return null;
    }
    return frame._element_shadow_roots.get(self);
}

pub fn insertAdjacentElement(
    self: *Element,
    position: []const u8,
    element: *Element,
    frame: *Frame,
) !?*Element {
    const target_node, const prev_node = self.asNode().findAdjacentNodes(position, .node) catch |err| switch (err) {
        // beforebegin/afterend with no parent is a no-op returning null.
        error.AdjacentNoParent => return null,
        else => return err,
    };
    _ = try target_node.insertBefore(element.asNode(), prev_node, frame);
    return element;
}

pub fn insertAdjacentText(
    self: *Element,
    where: []const u8,
    data: []const u8,
    frame: *Frame,
) !void {
    const target_node, const prev_node = self.asNode().findAdjacentNodes(where, .node) catch |err| switch (err) {
        // beforebegin/afterend with no parent is a no-op.
        error.AdjacentNoParent => return,
        else => return err,
    };
    const text_node = try Frame.node_factory.createTextNode(frame, data);
    _ = try target_node.insertBefore(text_node, prev_node, frame);
}

pub fn setAttributeNode(self: *Element, attr: *Attribute, frame: *Frame) !?*Attribute {
    if (attr._element) |el| {
        if (el == self) {
            return attr;
        }
        attr._element = null;
        _ = try el.removeAttributeNode(attr, frame);
    }

    return self._attributes.putAttribute(attr, self, frame);
}

pub fn removeAttribute(self: *Element, name: String, frame: *Frame) !void {
    return self._attributes.delete(name, self, frame);
}

pub fn removeAttributeSafe(self: *Element, name: String, frame: *Frame) void {
    self._attributes.deleteSafe(name, self, frame);
}

pub fn toggleAttribute(self: *Element, name: String, force: ?bool, frame: *Frame) !bool {
    try Attribute.validateAttributeName(name);
    const has = try self.hasAttribute(name, frame);

    const should_add = force orelse !has;

    if (should_add and !has) {
        try self.setAttribute(name, String.empty, frame);
        return true;
    } else if (!should_add and has) {
        try self.removeAttribute(name, frame);
        return false;
    }

    return should_add;
}

pub fn removeAttributeNode(self: *Element, attr: *Attribute, frame: *Frame) !*Attribute {
    if (attr._element == null or attr._element.? != self) {
        return error.NotFound;
    }
    try self.removeAttribute(attr._name, frame);
    attr._element = null;
    return attr;
}

pub fn getAttributeNames(self: *const Element, frame: *Frame) ![][]const u8 {
    return self._attributes.getNames(frame.local_arena);
}

pub fn getAttributeNamedNodeMap(self: *Element, frame: *Frame) !*Attribute.NamedNodeMap {
    const gop = try frame._attribute_named_node_map_lookup.getOrPut(frame.arena, @intFromPtr(self));
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(Attribute.NamedNodeMap{ ._element = self });
    }
    return gop.value_ptr.*;
}

// The materialized style lives in the map of the element's own frame, not
// the caller's: attributeChange (which resyncs it) is dispatched on the owner
// frame, and a same-origin script can reach an element in another frame.
pub fn getOrCreateStyle(self: *Element, frame: *Frame) !*CSSStyleProperties {
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_styles.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try CSSStyleProperties.init(self, false, owner);
    }
    self._flags.has_inline_style = true;
    return gop.value_ptr.*;
}

pub fn getStyle(self: *Element, frame: *Frame) ?*CSSStyleProperties {
    if (!self._flags.has_inline_style) {
        return null;
    }
    return self.ownerFrame(frame)._element_styles.get(self);
}

// Marks the element as possibly having inline style once a `style` attribute
// lands on it. Attribute population paths that bypass attributeChange (the
// parser, cloneNode) call this after filling the list.
pub fn noteStyleAttribute(self: *Element) void {
    if (self._attributes.hasSafe(comptime .wrap("style"))) {
        self._flags.has_inline_style = true;
    }
}

pub fn setStyle(self: *Element, value: []const u8, frame: *Frame) !void {
    const style = try self.getOrCreateStyle(frame);
    try style.asCSSStyleDeclaration().setCssText(value, frame);
}

pub fn getClassList(self: *Element, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_class_lists.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap("class"),
        });
    }
    return gop.value_ptr.*;
}

pub fn setClassList(self: *Element, value: String, frame: *Frame) !void {
    const class_list = try self.getClassList(frame);
    try class_list.setValue(value, frame);
}

pub fn getPartList(self: *Element, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_part_lists.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap("part"),
        });
    }
    return gop.value_ptr.*;
}

pub fn getRelList(self: *Element, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_rel_lists.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap("rel"),
        });
    }
    return gop.value_ptr.*;
}

// The other DOMTokenList-reflected attributes (class and rel have dedicated
// lookups above).
pub const TokenListAttribute = enum { sizes, sandbox, @"for" };
pub const TokenListKey = struct { element: *Element, attribute: TokenListAttribute };
pub const TokenListLookup = std.AutoHashMapUnmanaged(TokenListKey, *collections.DOMTokenList);

pub fn getTokenList(self: *Element, comptime attribute: TokenListAttribute, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_token_lists.getOrPut(frame.arena, .{ .element = self, .attribute = attribute });
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap(@tagName(attribute)),
        });
    }
    return gop.value_ptr.*;
}

pub fn getDataset(self: *Element, frame: *Frame) !*DOMStringMap {
    const gop = try frame._element_datasets.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(DOMStringMap{
            ._element = self,
        });
    }
    return gop.value_ptr.*;
}

pub fn replaceChildren(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn replaceWith(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const ref_node = self.asNode();
    const parent = ref_node._parent orelse return;
    frame.domChanged();

    // Detect if the ref_node must be removed (by default) or kept.
    // We kept it when ref_node is present into the nodes list.
    var rm_ref_node = true;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // If a child is the ref node. We keep it at its own current position.
        if (child == ref_node) {
            rm_ref_node = false;
            continue;
        }

        // A DocumentFragment contributes its children, not itself
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.insertAllChildrenBefore(child, parent, ref_node);
            continue;
        }

        var previous_root: ?*Node = null;
        if (child._parent) |current_parent| {
            previous_root = child.getRootNode(.{});
            frame.removeNode(current_parent, child, .{ .reconnect_to = parent });
        }

        try frame.insertNodeRelative(
            parent,
            child,
            .{ .before = ref_node },
            .{ .previous_root = previous_root },
        );
    }

    // Re-check parent after insertNodeRelative since callbacks (e.g. connectedCallback)
    // could have already removed ref_node from parent.
    if (rm_ref_node and ref_node._parent == parent) {
        frame.removeNode(parent, ref_node, .{ .reconnect_to = null });
    }
}

pub fn remove(self: *Element, frame: *Frame) void {
    const node = self.asNode();
    const parent = node._parent orelse return;
    frame.domChanged();
    frame.removeNode(parent, node, .{ .reconnect_to = null });
}

pub fn focus(self: *Element, frame: *Frame) !void {
    if (self.asNode().isConnected() == false) {
        // a disconnected node cannot take focus
        return;
    }

    // Per HTML spec §6.4.4, an element must be "being rendered" (not
    // display:none on self or any ancestor) to be focusable.
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return;
    }

    const FocusEvent = @import("event/FocusEvent.zig");

    const new_target = self.asEventTarget();
    const doc = self.asNode().ownerDocument(frame) orelse frame.document;
    const old_active = doc._active_element;
    doc._active_element = self;

    if (old_active) |old| {
        if (old == self) {
            return;
        }

        const old_target = old.asEventTarget();

        // Dispatch blur on old element (no bubble, composed)
        const blur_event = try FocusEvent.initTrusted(comptime .wrap("blur"), .{ .composed = true, .relatedTarget = new_target }, frame);
        try frame._event_manager.dispatch(old_target, blur_event.asEvent());

        // Dispatch focusout on old element (bubbles, composed)
        const focusout_event = try FocusEvent.initTrusted(comptime .wrap("focusout"), .{ .bubbles = true, .composed = true, .relatedTarget = new_target }, frame);
        try frame._event_manager.dispatch(old_target, focusout_event.asEvent());
    }

    const old_related: ?*EventTarget = if (old_active) |old| old.asEventTarget() else null;

    // Dispatch focus on new element (no bubble, composed)
    const focus_event = try FocusEvent.initTrusted(comptime .wrap("focus"), .{ .composed = true, .relatedTarget = old_related }, frame);
    try frame._event_manager.dispatch(new_target, focus_event.asEvent());

    // Dispatch focusin on new element (bubbles, composed)
    const focusin_event = try FocusEvent.initTrusted(comptime .wrap("focusin"), .{ .bubbles = true, .composed = true, .relatedTarget = old_related }, frame);
    try frame._event_manager.dispatch(new_target, focusin_event.asEvent());
}

pub fn blur(self: *Element, frame: *Frame) !void {
    const doc = self.asNode().ownerDocument(frame) orelse frame.document;
    if (doc._active_element != self) return;

    doc._active_element = null;

    const FocusEvent = @import("event/FocusEvent.zig");
    const old_target = self.asEventTarget();

    // Dispatch blur (no bubble, composed)
    const blur_event = try FocusEvent.initTrusted(comptime .wrap("blur"), .{ .composed = true }, frame);
    try frame._event_manager.dispatch(old_target, blur_event.asEvent());

    // Dispatch focusout (bubbles, composed)
    const focusout_event = try FocusEvent.initTrusted(comptime .wrap("focusout"), .{ .bubbles = true, .composed = true }, frame);
    try frame._event_manager.dispatch(old_target, focusout_event.asEvent());
}

pub fn getChildren(self: *Element, frame: *Frame) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, frame);
}

pub fn append(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().appendNodes(nodes, frame);
}

pub fn prepend(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().prependNodes(nodes, frame);
}

pub fn moveBefore(self: *Element, node: js.Value, child: js.Value, frame: *Frame) !void {
    return self.asNode().moveBefore(node, child, frame);
}

pub fn before(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, node, frame);
    }
}

pub fn after(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const viable_next = Node.NodeOrText.viableNextSibling(node, nodes);

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, viable_next, frame);
    }
}

pub fn firstElementChild(self: *Element) ?*Element {
    var maybe_child = self.asNode().firstChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.nextSibling();
    }
    return null;
}

pub fn lastElementChild(self: *Element) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn nextElementSibling(self: *Element) ?*Element {
    var maybe_sibling = self.asNode().nextSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Element)) |el| return el;
        maybe_sibling = sibling.nextSibling();
    }
    return null;
}

pub fn previousElementSibling(self: *Element) ?*Element {
    var maybe_sibling = self.asNode().previousSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Element)) |el| return el;
        maybe_sibling = sibling.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Element) usize {
    var count: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element) != null) {
            count += 1;
        }
    }
    return count;
}

pub fn matches(self: *Element, selector: []const u8, frame: *Frame) !bool {
    return Selector.matches(self, selector, frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn querySelector(self: *Element, selector: []const u8, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), selector, frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn querySelectorAll(self: *Element, input: []const u8, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn getAnimations(_: *const Element) []*Animation {
    return &.{};
}

pub fn animate(_: *Element, _: ?js.Object, _: ?js.Object, frame: *Frame) !*Animation {
    return Animation.init(frame);
}

pub fn closest(self: *Element, input: []const u8, frame: *Frame) !?*Element {
    if (input.len == 0) {
        return error.SyntaxError;
    }

    const selector = try Selector.cachedParse(frame._session.browser, input);

    var current: ?*Element = self;
    while (current) |el| {
        if (try Selector.matchesWithScope(el, selector, self, frame)) {
            return el;
        }

        const parent = el.asNode()._parent orelse break;

        if (parent.is(ShadowRoot) != null) {
            break;
        }

        current = parent.is(Element);
    }
    return null;
}

pub fn parentElement(self: *Element) ?*Element {
    return self.asNode().parentElement();
}

/// Cache for visibility checks - re-exported from StyleManager for convenience.
pub const VisibilityCache = StyleManager.VisibilityCache;

/// Cache for pointer-events checks - re-exported from StyleManager for convenience.
pub const PointerEventsCache = StyleManager.PointerEventsCache;

// Style checks go through the StyleManager of the element's own frame, not
// the caller's: its stylesheets and materialized inline styles are per-frame,
// and a same-origin script can reach an element in another frame.
pub fn hasPointerEventsNone(self: *Element, cache: ?*PointerEventsCache, frame: *Frame) bool {
    return self.ownerFrame(frame)._style_manager.hasPointerEventsNone(self, cache);
}

pub fn checkVisibilityCached(self: *Element, cache: ?*VisibilityCache, frame: *Frame, comptime access: StyleManager.InlineAccess) bool {
    return !self.ownerFrame(frame)._style_manager.isHidden(self, cache, .{}, access);
}

// The element's own display:none only, no ancestor walk. For a child or
// sibling of an element already known to be visible, that is the whole
// answer: they share the visible ancestor chain — and the owner frame, which
// the caller resolves once rather than per element.
fn isVisibleSelf(self: *Element, style_manager: *StyleManager) bool {
    return !style_manager.hasDisplayNone(self, .materialize);
}

const CheckVisibilityOpts = struct {
    checkOpacity: bool = false,
    checkVisibilityCSS: bool = false,
    opacityProperty: bool = false,
    visibilityProperty: bool = false,
};
pub fn checkVisibility(self: *Element, opts_: ?CheckVisibilityOpts, frame: *Frame) bool {
    const opts = opts_ orelse CheckVisibilityOpts{};
    return !self.ownerFrame(frame)._style_manager.isHidden(self, null, .{
        .check_opacity = opts.checkOpacity or opts.opacityProperty,
        .check_visibility = opts.visibilityProperty or opts.checkVisibilityCSS,
    }, .materialize);
}

pub const Axis = enum {
    width,
    height,

    // The axis' value, and whether it's explicit or the default
    pub const State = struct {
        value: f64,
        explicit: bool = false,
    };
};

pub fn getElementAxis(self: *Element, frame: *Frame, comptime axis: Axis) Axis.State {
    if (self.getStyle(frame)) |style| {
        const decl = style.asCSSStyleDeclaration();
        if (CSS.parseDimensionViewport(decl.getPropertyValue(@tagName(axis), frame), frame)) |v| {
            return .{ .value = v, .explicit = true };
        }
    }

    switch (self.getTag()) {
        // Root containers get large default size to contain descendant positions.
        // With calculateDocumentPosition using linear depth scaling (100px per level),
        // even very deep trees (100 levels) stay within 10,000px.
        // 100M pixels is plausible for very long documents.
        .html, .body => return .{ .value = if (axis == .width) 1920.0 else 100_000_000.0 },
        .img, .iframe => {
            if (self.getAttributeSafe(comptime .wrap(@tagName(axis)))) |attr| {
                if (std.fmt.parseFloat(f64, attr)) |parsed| {
                    return .{ .value = parsed, .explicit = true };
                } else |_| {}
            }
        },
        else => {},
    }

    return .{ .value = 5.0 };
}

// We can't do this correctly without full styles and more rendering. We also
// can't just ignore the children since some sites append nodes until a certain
// width / height treshold is reached. If the size isn't explicit, we fallback
// to the content size.
pub fn getClientWidth(self: *Element, frame: *Frame) f64 {
    return self.clientAxis(frame, .width);
}

pub fn getClientHeight(self: *Element, frame: *Frame) f64 {
    return self.clientAxis(frame, .height);
}

fn clientAxis(self: *Element, frame: *Frame, comptime axis: Axis) f64 {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return 0.0;
    }
    return self.viewportAxis(frame, axis) orelse self.boxAxis(frame, axis);
}

fn viewportAxis(self: *Element, frame: *Frame, comptime axis: Axis) ?f64 {
    const tag = self.getTag();
    if (tag != .html and tag != .body) {
        return null;
    }
    const doc = self.asNode().ownerDocument(frame) orelse frame.document;
    if ((tag == .body) != doc.isQuirksMode()) {
        return null;
    }
    // In quicks mode, the root element (the body) reports the viewport for
    // clientWidth and clientHeight rather than its own MASSIVE box. This
    // fixes jstracker's uiContourMap which attempts to tile the clientHeight
    // of the body. (https://github.com/lightpanda-io/browser/issues/3251)
    const viewport = frame._page.getViewport();
    return @floatFromInt(if (axis == .width) viewport.width else viewport.height);
}

// Caller must have made sure self is visible.
pub fn boxAxis(self: *Element, frame: *Frame, comptime axis: Axis) f64 {
    const own = self.getElementAxis(frame, axis);
    if (own.explicit) {
        // an explicitly set value always wins
        return own.value;
    }

    const tag = self.getTag();
    if (tag == .html or tag == .body) {
        // html/body return their set value regardless of children.
        return own.value;
    }

    return @max(own.value, self.contentAxis(frame, axis));
}

pub fn getBoundingClientRect(self: *Element, frame: *Frame) !*DOMRect {
    return DOMRect.create(self.boundingClientRectValues(frame), frame._factory);
}

// Plain rect values, no JS-backed allocation: the internal fast path shared by
// getBoundingClientRect, getClientRects, and IntersectionObserver. A DOMRect is
// only materialized at the JS boundary.
pub fn boundingClientRectValues(self: *Element, frame: *Frame) DOMRect.Data {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return .{};
    }
    return self.boundingClientRectValuesForVisible(frame);
}

// Some cases need the bounding rect but have already done the visibility check.
pub fn boundingClientRectValuesForVisible(self: *Element, frame: *Frame) DOMRect.Data {
    return .{
        .x = self.horizontalPosition(frame),
        .y = calculateDocumentPosition(self.asNode()),
        .width = self.boxAxis(frame, .width),
        .height = self.boxAxis(frame, .height),
    };
}

pub fn getClientRects(self: *Element, frame: *Frame) ![]*DOMRect {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return &.{};
    }
    const rects = try frame.local_arena.alloc(*DOMRect, 1);
    rects[0] = try DOMRect.create(self.boundingClientRectValuesForVisible(frame), frame._factory);
    return rects;
}

// Scroll positions live in the map of the element's own frame — not the
// caller's, which differs when a same-origin script scrolls an element in
// another frame (e.g. inside an iframe). All scroll accessors resolve the
// owner frame first so the state, the fired events and the document
// comparison stay in the element's frame.
pub fn getScrollTop(self: *Element, frame: *Frame) u32 {
    const owner = self.ownerFrame(frame);
    const pos = owner._element_scroll_positions.get(self) orelse return 0;
    return pos.y;
}

pub fn setScrollTop(self: *Element, value: i32, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const new_y: u32 = @intCast(@max(0, value));
    if (gop.value_ptr.y != new_y) {
        gop.value_ptr.y = new_y;
        try self.scheduleScrollEvents(owner);
    }
}

pub fn getScrollLeft(self: *Element, frame: *Frame) u32 {
    const owner = self.ownerFrame(frame);
    const pos = owner._element_scroll_positions.get(self) orelse return 0;
    return pos.x;
}

pub fn setScrollLeft(self: *Element, value: i32, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const new_x: u32 = @intCast(@max(0, value));
    if (gop.value_ptr.x != new_x) {
        gop.value_ptr.x = new_x;
        try self.scheduleScrollEvents(owner);
    }
}

pub fn getScrollHeight(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return 0.0;
    }

    const height = self.getElementAxis(frame, .height).value;

    const tag = self.getTag();
    // As in getScrollWidth: the root containers carry artificial giant
    // defaults, and page-level overflow checks read them.
    if (tag == .html or tag == .body) {
        return height;
    }

    return @max(height, self.contentAxis(frame, .height));
}

pub fn getScrollWidth(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return 0.0;
    }

    const width = self.getElementAxis(frame, .width).value;

    const tag = self.getTag();
    // The root containers carry artificial giant defaults (1920 and
    // 100_000_000, see getElementAxis). Stacking their children on
    // top would inflate a value sites read to detect page overflow.
    if (tag == .html or tag == .body) {
        return width;
    }

    return @max(width, self.contentAxis(frame, .width));
}

// One axis of the direct child elements' size: laid end to end on a single
// row for the width, stacked for the height.
//
// The dummy layout engine has no line-breaking, and an element only overflows
// horizontally when its children don't wrap (white-space:nowrap, a flex row, an
// inline-block strip), so the single-row assumption covers the case that
// matters. We can't detect the layout mode to do better: getStyle() sees only
// the inline `style=` attribute, and the computed cascade resolves stylesheet
// rules for `display:none` and `visibility` alone.
//
// Only direct children are measured, never the whole subtree. This runs on
// every size read, and recursing would make an element's cost O(subtree)
// rather than O(fan-out). It also keeps an ancestor from growing in lockstep
// with its descendants, so "append until the track outgrows its shell" still
// crosses the threshold.
//
// Growing with the child count is the point: JS that appends content until
// `scrollWidth` passes a threshold (the infinite-marquee idiom) never
// terminates when the metric ignores what it just inserted.
//
// Text children are not measured. Estimating a text run from its length would
// need a per-character advance, which in turn has to track font-size or
// "shrink the font until it fits" loops stop converging — and it would report
// overflow for practically every element containing text, since a few words
// already exceed the default box. Element children are what content grown by
// script actually consists of.
fn contentAxis(self: *Element, frame: *Frame, comptime axis: Axis) f64 {
    var total: f64 = 0;
    const style_manager = &self.ownerFrame(frame)._style_manager;

    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            if (el.isVisibleSelf(style_manager)) {
                total += el.getElementAxis(frame, axis).value;
            }
        }
    }

    return total;
}

// Unlike clientHeight, the root's offsetHeight is its box (the document
// extent), so it stays on the synthetic root default.
pub fn getOffsetHeight(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return 0.0;
    }
    return self.boxAxis(frame, .height);
}

pub fn getOffsetWidth(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return 0.0;
    }
    return self.boxAxis(frame, .width);
}

pub fn getOffsetTop(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return 0.0;
    }
    return calculateDocumentPosition(self.asNode());
}

pub fn getOffsetLeft(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame, .materialize)) {
        return 0.0;
    }
    return self.horizontalPosition(frame);
}

pub fn getOffsetParent(self: *Element, frame: *Frame) ?*Element {
    if (!self.asNode().isConnected() or !self.checkVisibilityCached(null, frame, .materialize)) {
        return null;
    }

    switch (self.getTag()) {
        .html, .body => return null,
        else => {},
    }

    const self_position = self.positionStyle(frame);
    if (std.mem.eql(u8, self_position, "fixed")) {
        return null;
    }
    const self_static = self_position.len == 0 or std.mem.eql(u8, self_position, "static");

    var node: ?*Node = self.asNode()._parent;
    while (node) |n| {
        if (n.is(ShadowRoot)) |sr| {
            // this always pokes through the shadow dom
            node = sr.getHost().asNode();
            continue;
        }
        const ancestor = n.is(Element) orelse break;

        const tag = ancestor.getTag();
        if (tag == .body) {
            return ancestor;
        }
        const position = ancestor.positionStyle(frame);
        if (position.len > 0 and !std.mem.eql(u8, position, "static")) {
            return ancestor;
        }
        if (self_static and (tag == .td or tag == .th or tag == .table)) {
            return ancestor;
        }
        node = n._parent;
    }
    return null;
}

fn positionStyle(self: *Element, frame: *Frame) []const u8 {
    const style = self.getStyle(frame) orelse return "";
    return style.asCSSStyleDeclaration().getPropertyValue("position", frame);
}

pub fn getClientTop(_: *Element) f64 {
    // Border width - in our dummy layout, we don't apply borders to layout
    return 0.0;
}

pub fn getClientLeft(_: *Element) f64 {
    // Border width - in our dummy layout, we don't apply borders to layout
    return 0.0;
}

// Calculates document position by counting all nodes that appear before this one
// in tree order, but only traversing the "left side" of the tree.
//
// This walks up from the target node to the root, and at each level counts:
// 1. All previous siblings and their descendants
// 2. The parent itself
//
// Example:
//   <body>              → y=0
//     <h1>Text</h1>     → y=1    (body=1)
//     <h2>              → y=2    (body=1 + h1=1)
//       <a>Link1</a>    → y=3    (body=1 + h1=1 + h2=1)
//     </h2>
//     <p>Text</p>       → y=5    (body=1 + h1=1 + h2=2)
//     <h2>              → y=6    (body=1 + h1=1 + h2=2 + p=1)
//       <a>Link2</a>    → y=7    (body=1 + h1=1 + h2=2 + p=1 + h2=1)
//     </h2>
//   </body>
//
// Trade-offs:
// - O(depth × siblings × subtree_height) - only left-side traversal
// - Linear scaling: 5px per node
// - Perfect document order, guaranteed unique positions
// - Compact coordinates (1000 nodes ≈ 5,000px)
fn calculateDocumentPosition(node: *Node) f64 {
    var position: f64 = 0.0;
    var current = node;

    // Walk up to root, counting preceding nodes
    while (current.parentNode()) |parent| {
        // Count all previous siblings and their descendants
        var sibling = parent.firstChild();
        while (sibling) |s| {
            if (s == current) break;
            position += countSubtreeNodes(s);
            sibling = s.nextSibling();
        }

        // Count the parent itself
        position += 1.0;
        current = parent;
    }

    return position * 5.0; // 5px per node
}

// Counts total nodes in a subtree (node + all descendants)
fn countSubtreeNodes(node: *Node) f64 {
    var count: f64 = 1.0; // Count this node

    var child = node.firstChild();
    while (child) |c| {
        count += countSubtreeNodes(c);
        child = c.nextSibling();
    }

    return count;
}

// The horizontal position follows the same single-row assumption as
// contentAxis: an element sits to the right of the visible element
// siblings before it.

// translateX is commonly used to shift elements around, e.g. in a carousel to
// shift things around. So we honor any transform: translateX inline styles.
pub fn horizontalPosition(self: *Element, frame: *Frame) f64 {
    var x: f64 = 0.0;
    var current = self.asNode();
    const style_manager = &self.ownerFrame(frame)._style_manager;

    if (self.getStyle(frame)) |style| {
        x += CSS.parseTranslateX(style.asCSSStyleDeclaration().getPropertyValue("transform", frame));
    }

    while (current.parentNode()) |parent| {
        if (parent.is(Element)) |el| {
            if (el.getStyle(frame)) |style| {
                x += CSS.parseTranslateX(style.asCSSStyleDeclaration().getPropertyValue("transform", frame));
            }
        }
        var sibling = parent.firstChild();
        while (sibling) |s| : (sibling = s.nextSibling()) {
            if (s == current) break;
            if (s.is(Element)) |el| {
                if (el.isVisibleSelf(style_manager)) {
                    x += el.getElementAxis(frame, .width).value;
                }
            }
        }
        current = parent;
    }

    return x;
}

pub fn getElementsByTagName(self: *Element, tag_name: []const u8, frame: *Frame) !Node.GetElementsByTagNameResult {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Element, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Element, class_name: []const u8, frame: *Frame) !collections.NodeLive(.class_name) {
    return self.asNode().getElementsByClassName(class_name, frame);
}

pub fn clone(self: *Element, deep: bool, frame: *Frame) !*Node {
    const tag_name = self.getTagNameDump();
    const node = try Frame.node_factory.createElementNS(frame, self._namespace, tag_name, &self._attributes);

    // A namespace outside the built-in set lives in a side table; the clone
    // must report the same namespaceURI.
    if (self._namespace == .unknown) {
        if (frame._element_namespace_uris.get(self)) |uri| {
            try frame._element_namespace_uris.put(frame.arena, node.as(Element), uri);
        }
    }

    // Allow element-specific types to copy their runtime state
    _ = Element.Build.call(node.as(Element), "cloned", .{ self, node.as(Element), deep, frame }) catch |err| {
        log.err(.dom, "element.clone.failed", .{ .err = err });
    };

    // Per spec, a clonable shadow root is cloned along with its host — its
    // children always deep-cloned, even when the host clone is shallow.
    if (self.hostedShadowRoot(frame)) |shadow| {
        if (shadow._clonable) {
            const cloned_shadow = node.as(Element).attachShadow(.{
                .mode = shadow._mode,
                .clonable = true,
                .delegates_focus = shadow._delegates_focus,
                .slot_assignment = shadow._slot_assignment,
                .serializable = shadow._serializable,
                .declarative = shadow._declarative,
            }, frame) catch return error.CloneError;

            const cloned_shadow_node = cloned_shadow.asNode();
            var shadow_child_it = shadow.asNode().childrenIterator();
            while (shadow_child_it.next()) |child| {
                if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                    try frame.appendNode(cloned_shadow_node, cloned_child, .{});
                }
            }
        }
    }

    if (deep) {
        var child_it = self.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                try frame.appendNode(node, cloned_child, .{});
            }
        }
    }

    return node;
}

pub fn scrollIntoViewIfNeeded(self: *Element, center_if_needed: ?bool, frame: *Frame) void {
    _ = center_if_needed;
    const y = calculateDocumentPosition(self.asNode());
    const scroll_y: f64 = @floatFromInt(frame.window.getScrollY());
    const viewport_height: f64 = @floatFromInt(frame.window.getInnerHeight(frame));
    if (y >= scroll_y and y <= scroll_y + viewport_height) {
        return;
    }
    self.scrollIntoView(null, frame);
}

const ScrollIntoViewOpts = union {
    align_to_top: bool,
    obj: js.Object,
};
pub fn scrollIntoView(self: *Element, opts: ?ScrollIntoViewOpts, frame: *Frame) void {
    _ = opts;
    // Scroll the window so the element's top is brought into the viewport.
    // Positions come from the faux-layout document position (top = preorder
    // depth-scaled y), the same source getBoundingClientRect uses.
    const y = calculateDocumentPosition(self.asNode());
    frame.window.scrollTo(.{ .x = 0 }, @trunc(@max(0, y)), frame) catch {};
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        behavior: []const u8 = "",
        left: ?i32 = null,
        top: ?i32 = null,
    };
};

pub fn scrollTo(self: *Element, opts: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts orelse return;
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const old_x = gop.value_ptr.x;
    const old_y = gop.value_ptr.y;
    switch (o) {
        .x => |x| {
            gop.value_ptr.x = @intCast(@max(0, x));
            gop.value_ptr.y = @intCast(@max(0, y orelse 0));
        },
        .opts => |dict| {
            if (dict.left) |left| gop.value_ptr.x = @intCast(@max(0, left));
            if (dict.top) |top| gop.value_ptr.y = @intCast(@max(0, top));
        },
    }
    if (gop.value_ptr.x != old_x or gop.value_ptr.y != old_y) {
        try self.scheduleScrollEvents(owner);
    }
}

// scrollBy(): like scrollTo() but relative to the current position.
pub fn scrollBy(self: *Element, opts: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts orelse return;
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const dx: i32, const dy: i32 = switch (o) {
        .x => |x| .{ x, y orelse 0 },
        .opts => |dict| .{ dict.left orelse 0, dict.top orelse 0 },
    };
    const old_x = gop.value_ptr.x;
    const old_y = gop.value_ptr.y;
    gop.value_ptr.x = @intCast(@max(0, @as(i32, @intCast(gop.value_ptr.x)) + dx));
    gop.value_ptr.y = @intCast(@max(0, @as(i32, @intCast(gop.value_ptr.y)) + dy));
    if (gop.value_ptr.x != old_x or gop.value_ptr.y != old_y) {
        try self.scheduleScrollEvents(owner);
    }
}

// Scrolling an element fires a scroll event and then a scrollend event,
// asynchronously and throttled, mirroring Window.scrollTo. Scrolls of the
// scrolling element (the root) are fired at the document instead.
// `frame` is the element's owner frame (resolved by the public accessors).
fn scheduleScrollEvents(self: *Element, frame: *Frame) !void {
    const gop = try frame._element_scroll_positions.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const task_pending = gop.value_ptr.state != .done;
    gop.value_ptr.state = .scroll;
    if (task_pending) {
        return;
    }

    const task = try frame._factory.create(ScrollEventTask{ .frame = frame, .element = self });
    errdefer {
        gop.value_ptr.state = .done;
        frame._factory.destroy(task);
    }
    try frame.js.scheduler.add(task, ScrollEventTask.run, 10, .{
        .name = "element.scrollEvents",
        .blocks_done = false,
        .finalizer = ScrollEventTask.cancelled,
    });
}

const ScrollEventTask = struct {
    frame: *Frame,
    element: *Element,

    fn eventTarget(self: *ScrollEventTask) *@import("EventTarget.zig") {
        if (self.frame.document.getDocumentElement() == self.element) {
            return self.frame.document.asEventTarget();
        }
        return self.element.asEventTarget();
    }

    // Scroll events fired at an element don't bubble; only document-level
    // scrolls (the scrolling element, dispatched at the document) do.
    fn bubbles(self: *ScrollEventTask) bool {
        return self.frame.document.getDocumentElement() == self.element;
    }

    fn cancelled(ptr: *anyopaque) void {
        const self: *ScrollEventTask = @ptrCast(@alignCast(ptr));
        if (self.frame._element_scroll_positions.getPtr(self.element)) |pos| {
            pos.state = .done;
        }
        self.frame._factory.destroy(self);
    }

    fn run(ptr: *anyopaque) anyerror!?u32 {
        const self: *ScrollEventTask = @ptrCast(@alignCast(ptr));
        const f = self.frame;
        const pos = f._element_scroll_positions.getPtr(self.element) orelse {
            f._factory.destroy(self);
            return null;
        };
        switch (pos.state) {
            .scroll => {
                pos.state = .end;
                self.dispatchEvent(comptime .wrap("scroll"));
                return 10;
            },
            .end => {
                pos.state = .done;
                defer f._factory.destroy(self);
                self.dispatchEvent(comptime .wrap("scrollend"));
                return null;
            },
            .done => {
                f._factory.destroy(self);
                return null;
            },
        }
    }

    fn dispatchEvent(self: *ScrollEventTask, comptime event_type: String) void {
        const Event = @import("Event.zig");
        const event = Event.initTrusted(event_type, .{ .bubbles = self.bubbles() }, self.frame._page) catch |err| {
            log.warn(.dom, "element.scroll.event", .{ .err = err });
            return;
        };
        self.frame._event_manager.dispatch(self.eventTarget(), event) catch |err| {
            log.warn(.dom, "element.scroll.dispatch", .{ .err = err });
        };
    }
};

pub fn format(self: *Element, writer: *std.Io.Writer) !void {
    try writer.writeByte('<');
    try writer.writeAll(self.getTagNameDump());

    for (self._attributes.entries()) |*attr| {
        try writer.print(" {f}", .{attr});
    }
    try writer.writeByte('>');
}

fn upperTagName(tag_name: *String, buf: []u8) []const u8 {
    if (tag_name.len > buf.len) {
        log.info(.dom, "tag.long.name", .{ .name = tag_name.str() });
        return tag_name.str();
    }
    const tag = tag_name.str();
    return std.ascii.upperString(buf, tag);
}

pub fn getTag(self: *const Element) Tag {
    return switch (self._type) {
        .html => blk: {
            const he = self.subtype(Html);
            break :blk switch (he._type) {
                .anchor => .anchor,
                .area => .area,
                .base => .base,
                .div => .div,
                .dl => .dl,
                .embed => .embed,
                .form => .form,
                .p => .p,
                .custom => .custom,
                .data => .data,
                .datalist => .datalist,
                .details => .details,
                .dialog => .dialog,
                .directory => .directory,
                .iframe => .iframe,
                .img => .img,
                .br => .br,
                .button => .button,
                .canvas => .canvas,
                .fieldset => .fieldset,
                .font => .font,
                .frameset => .frameset,
                .heading => he.subtype(Html.Heading)._tag,
                .label => .label,
                .legend => .legend,
                .li => .li,
                .map => .map,
                .marquee => .marquee,
                .ul => .ul,
                .ol => .ol,
                .object => .object,
                .optgroup => .optgroup,
                .output => .output,
                .picture => .picture,
                .param => .param,
                .pre => .pre,
                .generic => he.subtype(Html.Generic)._tag,
                .media => switch (he.subtype(Html.Media)._type) {
                    .audio => .audio,
                    .video => .video,
                    .generic => .media,
                },
                .meter => .meter,
                .mod => he.subtype(Html.Mod)._tag,
                .progress => .progress,
                .quote => he.subtype(Html.Quote)._tag,
                .script => .script,
                .select => .select,
                .slot => .slot,
                .source => .source,
                .span => .span,
                .option => .option,
                .table => .table,
                .table_caption => .caption,
                .table_cell => he.subtype(Html.TableCell)._tag,
                .table_col => he.subtype(Html.TableCol)._tag,
                .table_row => .tr,
                .table_section => he.subtype(Html.TableSection)._tag,
                .template => .template,
                .textarea => .textarea,
                .time => .time,
                .track => .track,
                .input => .input,
                .link => .link,
                .meta => .meta,
                .hr => .hr,
                .style => .style,
                .title => .title,
                .body => .body,
                .html => .html,
                .head => .head,
                .unknown => .unknown,
            };
        },
        .svg => self.subtype(Svg).getTag(),
    };
}

pub fn ownerFrame(self: *const Element, default: *Frame) *Frame {
    return self.asConstNode().ownerFrame(default);
}

pub const Tag = enum {
    address,
    anchor,
    audio,
    area,
    aside,
    article,
    b,
    blockquote,
    body,
    br,
    button,
    base,
    canvas,
    caption,
    circle,
    code,
    col,
    colgroup,
    custom,
    data,
    datalist,
    dd,
    details,
    del,
    dfn,
    dialog,
    div,
    directory,
    dl,
    dt,
    embed,
    ellipse,
    em,
    fieldset,
    figure,
    frameset,
    form,
    font,
    footer,
    g,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    heading,
    hgroup,
    hr,
    html,
    i,
    iframe,
    img,
    input,
    ins,
    label,
    legend,
    li,
    line,
    link,
    main,
    map,
    marquee,
    media,
    menu,
    meta,
    meter,
    nav,
    noscript,
    object,
    ol,
    optgroup,
    option,
    output,
    p,
    path,
    param,
    picture,
    polygon,
    polyline,
    pre,
    progress,
    quote,
    rect,
    s,
    script,
    section,
    select,
    slot,
    source,
    span,
    strong,
    style,
    sub,
    summary,
    sup,
    svg,
    table,
    time,
    tbody,
    td,
    text,
    template,
    textarea,
    tfoot,
    th,
    thead,
    title,
    tr,
    track,
    ul,
    video,
    unknown,

    // If the tag is "unknown", we can't use the optimized tag matching, but
    // need to fallback to the actual tag name
    pub fn parseForMatch(lower: []const u8) ?Tag {
        const tag = std.meta.stringToEnum(Tag, lower) orelse return null;
        return switch (tag) {
            .unknown, .custom => null,
            else => tag,
        };
    }

    pub fn isBlock(self: Tag) bool {
        // zig fmt: off
        return switch (self) {
            // Semantic Layout
            .article, .aside, .footer, .header, .main, .nav, .section,
            // Grouping / Containers
            .address, .div, .fieldset, .figure, .p,
            // Headings
            .h1, .h2, .h3, .h4, .h5, .h6,
            // Lists
            .dl, .ol, .ul,
            // Preformatted / Quotes
            .blockquote, .pre,
            // Tables
            .table,
            // Other
            .hr,
            => true,
            else => false,
        };
        // zig fmt: on
    }

    pub fn isMetadata(self: Tag) bool {
        return switch (self) {
            .base, .head, .link, .meta, .noscript, .script, .style, .template, .title => true,
            else => false,
        };
    }

    // UA stylesheet display:none defaults per HTML Rendering §15.3.1
    // "Hidden elements" (https://html.spec.whatwg.org/multipage/rendering.html#hidden-elements).
    // The spec also lists basefont, noembed, noframes, rp; those tags are
    // obsolete and not represented in this enum, so they fall through to
    // `.unknown`/`.custom` and aren't matched here.
    pub fn isHiddenByUaStylesheet(self: Tag) bool {
        return switch (self) {
            .area,
            .base,
            .datalist,
            .head,
            .link,
            .meta,
            .noscript,
            .param,
            .script,
            .source,
            .style,
            .template,
            .title,
            .track,
            => true,
            else => false,
        };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Element);

    pub const Meta = struct {
        pub const name = "Element";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const tagName = bridge.accessor(_tagName, null, .{});
    fn _tagName(self: *Element, frame: *Frame) []const u8 {
        return self.getTagNameSpec(&frame.buf);
    }
    // the frame-aware variant returns the original URI for namespaces
    // outside the built-in set instead of the placeholder
    pub const namespaceURI = bridge.accessor(Element.getNamespaceUri, null, .{});

    pub const innerText = bridge.accessor(_innerText, Element.setInnerText, .{ .ce_reactions = true });
    fn _innerText(self: *Element, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getInnerText(&buf.writer, frame);
        return buf.written();
    }

    pub const outerHTML = bridge.accessor(_getOuterHTML, _setOuterHTML, .{ .ce_reactions = true });
    fn _getOuterHTML(self: *Element, frame: *Frame) ![]const u8 {
        // local_arena: serialization is read-only and the returned string is
        // converted to v8 before this call returns. No JS runs in between.
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getOuterHTML(&buf.writer, frame);
        return buf.written();
    }
    fn _setOuterHTML(self: *Element, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString] DOMString`: a JS null becomes "", not "null".
        return self.setOuterHTML(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }

    pub const innerHTML = bridge.accessor(_getInnerHTML, _setInnerHTML, .{ .ce_reactions = true });
    fn _getInnerHTML(self: *Element, frame: *Frame) ![]const u8 {
        // local_arena: read-only serialization, result converted to v8 before
        // returning; no JS runs in between.
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getInnerHTML(&buf.writer, frame);
        return buf.written();
    }
    fn _setInnerHTML(self: *Element, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString] DOMString`: a JS null becomes "", not "null".
        return self.setInnerHTML(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }

    pub const getHTML = bridge.function(_getHTML, .{});
    const GetHTMLOpts = struct {
        serializableShadowRoots: bool = false,
        shadowRoots: []const *ShadowRoot = &.{},
    };
    fn _getHTML(self: *Element, opts_: ?GetHTMLOpts, frame: *Frame) ![]const u8 {
        const opts = opts_ orelse GetHTMLOpts{};
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getHTML(.{
            .shadow_roots = opts.shadowRoots,
            .serializable_shadow_roots = opts.serializableShadowRoots,
        }, &buf.writer, frame);
        return buf.written();
    }

    pub const prefix = bridge.accessor(Element._prefix, null, .{});

    pub const setAttribute = bridge.function(_setAttribute, .{ .ce_reactions = true });
    fn _setAttribute(self: *Element, name: String, value: js.Value, frame: *Frame) !void {
        return self.setAttribute(name, .wrap(try value.toStringSlice()), frame);
    }

    pub const setAttributeNS = bridge.function(_setAttributeNS, .{ .ce_reactions = true });
    fn _setAttributeNS(self: *Element, maybe_ns: ?[]const u8, qn: []const u8, value: js.Value, frame: *Frame) !void {
        return self.setAttributeNS(maybe_ns, qn, .wrap(try value.toStringSlice()), frame);
    }

    pub const localName = bridge.accessor(Element.getLocalName, null, .{});
    pub const id = bridge.accessor(Element.getId, Element.setId, .{ .ce_reactions = true });
    pub const slot = bridge.accessor(Element.getSlot, Element.setSlot, .{ .ce_reactions = true });
    pub const role = ariaAccessor("role");
    pub const ariaAtomic = ariaAccessor("aria-atomic");
    pub const ariaAutoComplete = ariaAccessor("aria-autocomplete");
    pub const ariaBrailleLabel = ariaAccessor("aria-braillelabel");
    pub const ariaBrailleRoleDescription = ariaAccessor("aria-brailleroledescription");
    pub const ariaBusy = ariaAccessor("aria-busy");
    pub const ariaChecked = ariaAccessor("aria-checked");
    pub const ariaColCount = ariaAccessor("aria-colcount");
    pub const ariaColIndex = ariaAccessor("aria-colindex");
    pub const ariaColIndexText = ariaAccessor("aria-colindextext");
    pub const ariaColSpan = ariaAccessor("aria-colspan");
    pub const ariaCurrent = ariaAccessor("aria-current");
    pub const ariaDescription = ariaAccessor("aria-description");
    pub const ariaDisabled = ariaAccessor("aria-disabled");
    pub const ariaExpanded = ariaAccessor("aria-expanded");
    pub const ariaHasPopup = ariaAccessor("aria-haspopup");
    pub const ariaHidden = ariaAccessor("aria-hidden");
    pub const ariaInvalid = ariaAccessor("aria-invalid");
    pub const ariaKeyShortcuts = ariaAccessor("aria-keyshortcuts");
    pub const ariaLabel = ariaAccessor("aria-label");
    pub const ariaLevel = ariaAccessor("aria-level");
    pub const ariaLive = ariaAccessor("aria-live");
    pub const ariaModal = ariaAccessor("aria-modal");
    pub const ariaMultiLine = ariaAccessor("aria-multiline");
    pub const ariaMultiSelectable = ariaAccessor("aria-multiselectable");
    pub const ariaOrientation = ariaAccessor("aria-orientation");
    pub const ariaPlaceholder = ariaAccessor("aria-placeholder");
    pub const ariaPosInSet = ariaAccessor("aria-posinset");
    pub const ariaPressed = ariaAccessor("aria-pressed");
    pub const ariaReadOnly = ariaAccessor("aria-readonly");
    pub const ariaRelevant = ariaAccessor("aria-relevant");
    pub const ariaRequired = ariaAccessor("aria-required");
    pub const ariaRoleDescription = ariaAccessor("aria-roledescription");
    pub const ariaRowCount = ariaAccessor("aria-rowcount");
    pub const ariaRowIndex = ariaAccessor("aria-rowindex");
    pub const ariaRowIndexText = ariaAccessor("aria-rowindextext");
    pub const ariaRowSpan = ariaAccessor("aria-rowspan");
    pub const ariaSelected = ariaAccessor("aria-selected");
    pub const ariaSetSize = ariaAccessor("aria-setsize");
    pub const ariaSort = ariaAccessor("aria-sort");
    pub const ariaValueMax = ariaAccessor("aria-valuemax");
    pub const ariaValueMin = ariaAccessor("aria-valuemin");
    pub const ariaValueNow = ariaAccessor("aria-valuenow");
    pub const ariaValueText = ariaAccessor("aria-valuetext");
    pub const dir = bridge.accessor(Element.getDir, Element.setDir, .{ .ce_reactions = true });
    pub const className = bridge.accessor(Element.getClassName, Element.setClassName, .{ .ce_reactions = true });
    pub const classList = bridge.accessor(Element.getClassList, Element.setClassList, .{ .ce_reactions = true });
    pub const part = bridge.accessor(Element.getPartList, null, .{});
    pub const dataset = bridge.accessor(Element.getDataset, null, .{});
    pub const style = bridge.accessor(Element.getOrCreateStyle, Element.setStyle, .{});
    pub const attributes = bridge.accessor(Element.getAttributeNamedNodeMap, null, .{});
    pub const hasAttribute = bridge.function(Element.hasAttribute, .{});
    pub const hasAttributeNS = bridge.function(Element.hasAttributeNS, .{});
    pub const hasAttributes = bridge.function(Element.hasAttributes, .{});
    pub const getAttribute = bridge.function(Element.getAttribute, .{});
    pub const getAttributeNS = bridge.function(Element.getAttributeNS, .{});
    pub const getAttributeNode = bridge.function(Element.getAttributeNode, .{});
    pub const setAttributeNode = bridge.function(Element.setAttributeNode, .{ .ce_reactions = true });
    pub const removeAttribute = bridge.function(Element.removeAttribute, .{ .ce_reactions = true });
    pub const toggleAttribute = bridge.function(Element.toggleAttribute, .{ .ce_reactions = true });
    pub const getAttributeNames = bridge.function(Element.getAttributeNames, .{});
    pub const removeAttributeNode = bridge.function(Element.removeAttributeNode, .{ .ce_reactions = true });
    pub const shadowRoot = bridge.accessor(Element.getShadowRoot, null, .{});
    pub const assignedSlot = bridge.accessor(Element.getAssignedSlot, null, .{});
    pub const attachShadow = bridge.function(_attachShadow, .{});
    pub const insertAdjacentHTML = bridge.function(Element.insertAdjacentHTML, .{ .ce_reactions = true });
    pub const setHTMLUnsafe = bridge.function(Element.setHTMLUnsafe, .{ .ce_reactions = true });
    pub const insertAdjacentElement = bridge.function(Element.insertAdjacentElement, .{ .ce_reactions = true });
    pub const insertAdjacentText = bridge.function(Element.insertAdjacentText, .{ .ce_reactions = true });

    const ShadowRootInit = struct {
        clonable: bool = false,
        delegatesFocus: bool = false,
        mode: String,
        serializable: bool = false,
        slotAssignment: ?String = null,
    };
    fn _attachShadow(self: *Element, init: ShadowRootInit, frame: *Frame) !*ShadowRoot {
        const mode: ShadowRoot.Mode = blk: {
            if (init.mode.eql(comptime .wrap("open"))) break :blk .open;
            if (init.mode.eql(comptime .wrap("closed"))) break :blk .closed;
            return error.InvalidArgument;
        };
        const slot_assignment: ShadowRoot.SlotAssignment = blk: {
            const sa = init.slotAssignment orelse break :blk .named;
            if (sa.eql(comptime .wrap("named"))) break :blk .named;
            if (sa.eql(comptime .wrap("manual"))) break :blk .manual;
            return error.InvalidArgument;
        };
        return self.attachShadow(.{
            .mode = mode,
            .delegates_focus = init.delegatesFocus,
            .slot_assignment = slot_assignment,
            .clonable = init.clonable,
            .serializable = init.serializable,
        }, frame);
    }
    pub const replaceChildren = bridge.function(Element.replaceChildren, .{ .ce_reactions = true });
    pub const replaceWith = bridge.function(Element.replaceWith, .{ .ce_reactions = true });
    pub const remove = bridge.function(Element.remove, .{ .ce_reactions = true });
    pub const append = bridge.function(Element.append, .{ .ce_reactions = true });
    pub const prepend = bridge.function(Element.prepend, .{ .ce_reactions = true });
    pub const moveBefore = bridge.function(Element.moveBefore, .{ .ce_reactions = true });
    pub const before = bridge.function(Element.before, .{ .ce_reactions = true });
    pub const after = bridge.function(Element.after, .{ .ce_reactions = true });
    pub const firstElementChild = bridge.accessor(Element.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Element.lastElementChild, null, .{});
    pub const nextElementSibling = bridge.accessor(Element.nextElementSibling, null, .{});
    pub const previousElementSibling = bridge.accessor(Element.previousElementSibling, null, .{});
    pub const childElementCount = bridge.accessor(Element.getChildElementCount, null, .{});
    pub const matches = bridge.function(Element.matches, .{});
    pub const webkitMatchesSelector = bridge.function(Element.matches, .{});
    pub const querySelector = bridge.function(Element.querySelector, .{});
    pub const querySelectorAll = bridge.function(Element.querySelectorAll, .{});
    pub const closest = bridge.function(Element.closest, .{});
    pub const getAnimations = bridge.function(Element.getAnimations, .{});
    pub const animate = bridge.function(Element.animate, .{});
    pub const checkVisibility = bridge.function(Element.checkVisibility, .{});
    pub const clientWidth = bridge.accessor(Element.getClientWidth, null, .{});
    pub const clientHeight = bridge.accessor(Element.getClientHeight, null, .{});
    pub const clientTop = bridge.accessor(Element.getClientTop, null, .{});
    pub const clientLeft = bridge.accessor(Element.getClientLeft, null, .{});
    pub const scrollTop = bridge.accessor(Element.getScrollTop, Element.setScrollTop, .{});
    pub const scrollLeft = bridge.accessor(Element.getScrollLeft, Element.setScrollLeft, .{});
    pub const scrollHeight = bridge.accessor(Element.getScrollHeight, null, .{});
    pub const scrollWidth = bridge.accessor(Element.getScrollWidth, null, .{});
    pub const offsetTop = bridge.accessor(Element.getOffsetTop, null, .{});
    pub const offsetLeft = bridge.accessor(Element.getOffsetLeft, null, .{});
    pub const offsetWidth = bridge.accessor(Element.getOffsetWidth, null, .{});
    pub const offsetHeight = bridge.accessor(Element.getOffsetHeight, null, .{});
    pub const offsetParent = bridge.accessor(Element.getOffsetParent, null, .{});
    pub const getClientRects = bridge.function(Element.getClientRects, .{});
    pub const getBoundingClientRect = bridge.function(Element.getBoundingClientRect, .{});
    pub const getElementsByTagName = bridge.function(Element.getElementsByTagName, .{});
    pub const getElementsByTagNameNS = bridge.function(Element.getElementsByTagNameNS, .{});
    pub const getElementsByClassName = bridge.function(Element.getElementsByClassName, .{});
    pub const children = bridge.accessor(Element.getChildren, null, .{});
    pub const focus = bridge.function(Element.focus, .{});
    pub const blur = bridge.function(Element.blur, .{});
    pub const scrollIntoView = bridge.function(Element.scrollIntoView, .{});
    pub const scrollIntoViewIfNeeded = bridge.function(Element.scrollIntoViewIfNeeded, .{});
    pub const scroll = bridge.function(Element.scrollTo, .{});
    pub const scrollTo = bridge.function(Element.scrollTo, .{});
    pub const scrollBy = bridge.function(Element.scrollBy, .{});

    fn ariaAccessor(comptime attr: []const u8) js.bridge.Accessor {
        const R = struct {
            pub fn get(self: *const Element) ?[]const u8 {
                return self.getAttributeSafe(.wrap(attr));
            }

            pub fn set(self: *Element, value: ?[]const u8, frame: *Frame) !void {
                if (value) |v| {
                    try self.setAttributeSafe(.wrap(attr), .wrap(v), frame);
                } else {
                    try self.removeAttribute(.wrap(attr), frame);
                }
            }
        };
        return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
    }
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the Element itself.
    pub fn call(self: *const Element, comptime func_name: []const u8, args: anytype) !bool {
        switch (self._type) {
            inline else => |tag| {
                const S = Subtype(tag);
                if (@hasDecl(S, "Build")) {
                    // The inner type has its own "call" method. Defer to it.
                    if (@hasDecl(S.Build, "call")) {
                        return S.Build.call(self.subtype(S), func_name, args);
                    }

                    // The inner type implements this function. Call it and we're done.
                    if (@hasDecl(S, func_name)) {
                        return @call(.auto, @field(S, func_name), args);
                    }
                }
            },
        }

        if (@hasDecl(Element.Build, func_name)) {
            // Our last resort - the element implements this function.
            try @call(.auto, @field(Element.Build, func_name), args);
            return true;
        }

        // inform our caller (the Node) that we didn't find anything that implemented
        // func_name and it should keep searching for a match.
        return false;
    }
};

const testing = @import("../../testing.zig");
test "WebApi: Element" {
    try testing.htmlRunner("element", .{});
}

test "Element: div chain slot size" {
    // Guard against accidental growth: new Element fields (e.g. _flags) must
    // fit in existing padding. Debug is larger from the _proto_canary fields.
    const Div = @import("element/html/Div.zig");
    const slot = comptime Factory.chainOffsetOf(Div, Div) + @sizeOf(Div);
    try testing.expectEqual(if (comptime lp.IS_DEBUG) 120 else 74, slot);
}
