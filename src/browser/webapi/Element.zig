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

const log = @import("../../log.zig");
const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const reflect = @import("../reflect.zig");

const Node = @import("Node.zig");
const CSS = @import("CSS.zig");
const ShadowRoot = @import("ShadowRoot.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const Animation = @import("animation/Animation.zig");
const DOMStringMap = @import("element/DOMStringMap.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");

pub const DOMRect = @import("DOMRect.zig");
pub const Svg = @import("element/Svg.zig");
pub const Html = @import("element/Html.zig");
pub const Attribute = @import("element/Attribute.zig");

const Element = @This();

pub const DatasetLookup = std.AutoHashMapUnmanaged(*Element, *DOMStringMap);
pub const StyleLookup = std.AutoHashMapUnmanaged(*Element, *CSSStyleProperties);
pub const ClassListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const RelListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const ShadowRootLookup = std.AutoHashMapUnmanaged(*Element, *ShadowRoot);
pub const AssignedSlotLookup = std.AutoHashMapUnmanaged(*Element, *Html.Slot);

pub const Namespace = enum(u8) {
    html,
    svg,
    mathml,
    xml,
    // We should keep the original value, but don't.  If this becomes important
    // consider storing it in a page lookup, like `_element_class_lists`, rather
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
        if (namespace.len == "http://www.w3.org/1999/xhtml".len) {
            // Common case, avoid the string comparion. Recklessly
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

_type: Type,
_proto: *Node,
_namespace: Namespace = .html,
_attributes: ?*Attribute.List = null,

pub const Type = union(enum) {
    html: *Html,
    svg: *Svg,
};

pub fn is(self: *Element, comptime T: type) ?*T {
    const type_name = @typeName(T);
    switch (self._type) {
        .html => |el| {
            if (T == Html) {
                return el;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.")) {
                return el.is(T);
            }
        },
        .svg => |svg| {
            if (T == Svg) {
                return svg;
            }
            if (comptime std.mem.startsWith(u8, type_name, "webapi.element.svg.")) {
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
    return self._proto;
}

pub fn asEventTarget(self: *Element) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn asConstNode(self: *const Element) *const Node {
    return self._proto;
}

pub fn attributesEql(self: *const Element, other: *Element) bool {
    if (self._attributes) |attr_list| {
        const other_list = other._attributes orelse return false;
        return attr_list.eql(other_list);
    }
    // Make sure no attrs in both sides.
    return other._attributes == null;
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

    // Compare attributes.
    if (!self.attributesEql(other)) {
        return false;
    }

    // Compare children.
    var self_iter = self.asNode().childrenIterator();
    var other_iter = other.asNode().childrenIterator();
    var self_count: usize = 0;
    var other_count: usize = 0;
    while (self_iter.next()) |self_node| : (self_count += 1) {
        const other_node = other_iter.next() orelse return false;
        other_count += 1;
        if (self_node.isEqualNode(other_node)) {
            continue;
        }

        return false;
    }

    // Make sure both have equal number of children.
    return self_count == other_count;
}

pub fn getTagNameLower(self: *const Element) []const u8 {
    switch (self._type) {
        .html => |he| switch (he._type) {
            .custom => |ce| {
                @branchHint(.unlikely);
                return ce._tag_name.str();
            },
            else => return switch (he._type) {
                .anchor => "a",
                .area => "area",
                .base => "base",
                .body => "body",
                .br => "br",
                .button => "button",
                .canvas => "canvas",
                .custom => |e| e._tag_name.str(),
                .data => "data",
                .datalist => "datalist",
                .dialog => "dialog",
                .directory => "dir",
                .div => "div",
                .embed => "embed",
                .fieldset => "fieldset",
                .font => "font",
                .form => "form",
                .generic => |e| e._tag_name.str(),
                .heading => |e| e._tag_name.str(),
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
                .media => |m| switch (m._type) {
                    .audio => "audio",
                    .video => "video",
                    .generic => "media",
                },
                .meta => "meta",
                .meter => "meter",
                .mod => |e| e._tag_name.str(),
                .object => "object",
                .ol => "ol",
                .optgroup => "optgroup",
                .option => "option",
                .output => "output",
                .p => "p",
                .param => "param",
                .pre => "pre",
                .progress => "progress",
                .quote => |e| e._tag_name.str(),
                .script => "script",
                .select => "select",
                .slot => "slot",
                .source => "source",
                .span => "span",
                .style => "style",
                .table => "table",
                .table_caption => "caption",
                .table_cell => |e| e._tag_name.str(),
                .table_col => |e| e._tag_name.str(),
                .table_row => "tr",
                .table_section => |e| e._tag_name.str(),
                .template => "template",
                .textarea => "textarea",
                .time => "time",
                .title => "title",
                .track => "track",
                .ul => "ul",
                .unknown => |e| e._tag_name.str(),
            },
        },
        .svg => |svg| return svg._tag_name.str(),
    }
}

pub fn getTagNameSpec(self: *const Element, buf: []u8) []const u8 {
    return switch (self._type) {
        .html => |he| switch (he._type) {
            .anchor => "A",
            .area => "AREA",
            .base => "BASE",
            .body => "BODY",
            .br => "BR",
            .button => "BUTTON",
            .canvas => "CANVAS",
            .custom => |e| upperTagName(&e._tag_name, buf),
            .data => "DATA",
            .datalist => "DATALIST",
            .dialog => "DIALOG",
            .directory => "DIR",
            .div => "DIV",
            .embed => "EMBED",
            .fieldset => "FIELDSET",
            .font => "FONT",
            .form => "FORM",
            .generic => |e| upperTagName(&e._tag_name, buf),
            .heading => |e| upperTagName(&e._tag_name, buf),
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
            .meta => "META",
            .media => |m| switch (m._type) {
                .audio => "AUDIO",
                .video => "VIDEO",
                .generic => "MEDIA",
            },
            .meter => "METER",
            .mod => |e| upperTagName(&e._tag_name, buf),
            .object => "OBJECT",
            .ol => "OL",
            .optgroup => "OPTGROUP",
            .option => "OPTION",
            .output => "OUTPUT",
            .p => "P",
            .param => "PARAM",
            .pre => "PRE",
            .progress => "PROGRESS",
            .quote => |e| upperTagName(&e._tag_name, buf),
            .script => "SCRIPT",
            .select => "SELECT",
            .slot => "SLOT",
            .source => "SOURCE",
            .span => "SPAN",
            .style => "STYLE",
            .table => "TABLE",
            .table_caption => "CAPTION",
            .table_cell => |e| upperTagName(&e._tag_name, buf),
            .table_col => |e| upperTagName(&e._tag_name, buf),
            .table_row => "TR",
            .table_section => |e| upperTagName(&e._tag_name, buf),
            .template => "TEMPLATE",
            .textarea => "TEXTAREA",
            .time => "TIME",
            .title => "TITLE",
            .track => "TRACK",
            .ul => "UL",
            .unknown => |e| switch (self._namespace) {
                .html => upperTagName(&e._tag_name, buf),
                .svg, .xml, .mathml, .unknown, .null => e._tag_name.str(),
            },
        },
        .svg => |svg| svg._tag_name.str(),
    };
}

pub fn getTagNameDump(self: *const Element) []const u8 {
    switch (self._type) {
        .html => return self.getTagNameLower(),
        .svg => |svg| return svg._tag_name.str(),
    }
}

pub fn getNamespaceURI(self: *const Element) ?[]const u8 {
    return self._namespace.toUri();
}

pub fn getLocalName(self: *Element) []const u8 {
    const name = self.getTagNameLower();
    if (std.mem.indexOfPos(u8, name, 0, ":")) |pos| {
        return name[pos + 1 ..];
    }

    return name;
}

// Wrapper methods that delegate to Html implementations
pub fn getInnerText(self: *Element, writer: *std.Io.Writer) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.getInnerText(writer);
}

pub fn setInnerText(self: *Element, text: []const u8, page: *Page) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.setInnerText(text, page);
}

pub fn insertAdjacentHTML(
    self: *Element,
    position: []const u8,
    html_or_xml: []const u8,
    page: *Page,
) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.insertAdjacentHTML(position, html_or_xml, page);
}

pub fn getOuterHTML(self: *Element, writer: *std.Io.Writer, page: *Page) !void {
    const dump = @import("../dump.zig");
    return dump.deep(self.asNode(), .{ .shadow = .skip }, writer, page);
}

pub fn setOuterHTML(self: *Element, html: []const u8, page: *Page) !void {
    const node = self.asNode();
    const parent = node._parent orelse return;

    page.domChanged();
    if (html.len > 0) {
        const fragment = (try Node.DocumentFragment.init(page)).asNode();
        try page.parseHtmlAsChildren(fragment, html);
        try page.insertAllChildrenBefore(fragment, parent, node);
    }

    page.removeNode(parent, node, .{ .will_be_reconnected = false });
}

pub fn getInnerHTML(self: *Element, writer: *std.Io.Writer, page: *Page) !void {
    const dump = @import("../dump.zig");
    return dump.children(self.asNode(), .{ .shadow = .skip }, writer, page);
}

pub fn setInnerHTML(self: *Element, html: []const u8, page: *Page) !void {
    const parent = self.asNode();

    // Remove all existing children
    page.domChanged();
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        page.removeNode(parent, child, .{ .will_be_reconnected = false });
    }

    // Fast path: skip parsing if html is empty
    if (html.len == 0) {
        return;
    }

    // Parse and add new children
    try page.parseHtmlAsChildren(parent, html);
}

pub fn getId(self: *const Element) []const u8 {
    return self.getAttributeSafe("id") orelse "";
}

pub fn setId(self: *Element, value: []const u8, page: *Page) !void {
    return self.setAttributeSafe("id", value, page);
}

pub fn getSlot(self: *const Element) []const u8 {
    return self.getAttributeSafe("slot") orelse "";
}

pub fn setSlot(self: *Element, value: []const u8, page: *Page) !void {
    return self.setAttributeSafe("slot", value, page);
}

pub fn getDir(self: *const Element) []const u8 {
    return self.getAttributeSafe("dir") orelse "";
}

pub fn setDir(self: *Element, value: []const u8, page: *Page) !void {
    return self.setAttributeSafe("dir", value, page);
}

pub fn getClassName(self: *const Element) []const u8 {
    return self.getAttributeSafe("class") orelse "";
}

pub fn setClassName(self: *Element, value: []const u8, page: *Page) !void {
    return self.setAttributeSafe("class", value, page);
}

pub fn attributeIterator(self: *Element) Attribute.InnerIterator {
    const attributes = self._attributes orelse return .{};
    return attributes.iterator();
}

pub fn getAttribute(self: *const Element, name: []const u8, page: *Page) !?[]const u8 {
    const attributes = self._attributes orelse return null;
    return attributes.get(name, page);
}

pub fn getAttributeSafe(self: *const Element, name: []const u8) ?[]const u8 {
    const attributes = self._attributes orelse return null;
    return attributes.getSafe(name);
}

pub fn hasAttribute(self: *const Element, name: []const u8, page: *Page) !bool {
    const attributes = self._attributes orelse return false;
    const value = try attributes.get(name, page);
    return value != null;
}

pub fn hasAttributeSafe(self: *const Element, name: []const u8) bool {
    const attributes = self._attributes orelse return false;
    return attributes.hasSafe(name);
}

pub fn hasAttributes(self: *const Element) bool {
    const attributes = self._attributes orelse return false;
    return attributes.isEmpty() == false;
}

pub fn getAttributeNode(self: *Element, name: []const u8, page: *Page) !?*Attribute {
    const attributes = self._attributes orelse return null;
    return attributes.getAttribute(name, self, page);
}

pub fn setAttribute(self: *Element, name: []const u8, value: []const u8, page: *Page) !void {
    try Attribute.validateAttributeName(name);
    const attributes = try self.getOrCreateAttributeList(page);
    _ = try attributes.put(name, value, self, page);
}

pub fn setAttributeSafe(self: *Element, name: []const u8, value: []const u8, page: *Page) !void {
    const attributes = try self.getOrCreateAttributeList(page);
    _ = try attributes.putSafe(name, value, self, page);
}

pub fn getOrCreateAttributeList(self: *Element, page: *Page) !*Attribute.List {
    return self._attributes orelse return self.createAttributeList(page);
}

pub fn createAttributeList(self: *Element, page: *Page) !*Attribute.List {
    std.debug.assert(self._attributes == null);
    const a = try page.arena.create(Attribute.List);
    a.* = .{ .normalize = self._namespace == .html };
    self._attributes = a;
    return a;
}

pub fn getShadowRoot(self: *Element, page: *Page) ?*ShadowRoot {
    const shadow_root = page._element_shadow_roots.get(self) orelse return null;
    if (shadow_root._mode == .closed) return null;
    return shadow_root;
}

pub fn getAssignedSlot(self: *Element, page: *Page) ?*Html.Slot {
    return page._element_assigned_slots.get(self);
}

pub fn attachShadow(self: *Element, mode_str: []const u8, page: *Page) !*ShadowRoot {
    if (page._element_shadow_roots.get(self)) |_| {
        return error.AlreadyHasShadowRoot;
    }
    const mode = try ShadowRoot.Mode.fromString(mode_str);
    const shadow_root = try ShadowRoot.init(self, mode, page);
    try page._element_shadow_roots.put(page.arena, self, shadow_root);
    return shadow_root;
}

pub fn insertAdjacentElement(
    self: *Element,
    position: []const u8,
    element: *Element,
    page: *Page,
) !void {
    const target_node, const prev_node = try self.asNode().findAdjacentNodes(position);
    _ = try target_node.insertBefore(element.asNode(), prev_node, page);
}

pub fn insertAdjacentText(
    self: *Element,
    where: []const u8,
    data: []const u8,
    page: *Page,
) !void {
    const text_node = try page.createTextNode(data);
    const target_node, const prev_node = try self.asNode().findAdjacentNodes(where);
    _ = try target_node.insertBefore(text_node, prev_node, page);
}

pub fn setAttributeNode(self: *Element, attr: *Attribute, page: *Page) !?*Attribute {
    if (attr._element) |el| {
        if (el == self) {
            return attr;
        }
        attr._element = null;
        _ = try el.removeAttributeNode(attr, page);
    }

    const attributes = try self.getOrCreateAttributeList(page);
    return attributes.putAttribute(attr, self, page);
}

pub fn removeAttribute(self: *Element, name: []const u8, page: *Page) !void {
    const attributes = self._attributes orelse return;
    return attributes.delete(name, self, page);
}

pub fn toggleAttribute(self: *Element, name: []const u8, force: ?bool, page: *Page) !bool {
    try Attribute.validateAttributeName(name);
    const has = try self.hasAttribute(name, page);

    const should_add = force orelse !has;

    if (should_add and !has) {
        try self.setAttribute(name, "", page);
        return true;
    } else if (!should_add and has) {
        try self.removeAttribute(name, page);
        return false;
    }

    return should_add;
}

pub fn removeAttributeNode(self: *Element, attr: *Attribute, page: *Page) !*Attribute {
    if (attr._element == null or attr._element.? != self) {
        return error.NotFound;
    }
    try self.removeAttribute(attr._name, page);
    attr._element = null;
    return attr;
}

pub fn getAttributeNames(self: *const Element, page: *Page) ![][]const u8 {
    const attributes = self._attributes orelse return &.{};
    return attributes.getNames(page);
}

pub fn getAttributeNamedNodeMap(self: *Element, page: *Page) !*Attribute.NamedNodeMap {
    const gop = try page._attribute_named_node_map_lookup.getOrPut(page.arena, @intFromPtr(self));
    if (!gop.found_existing) {
        const attributes = try self.getOrCreateAttributeList(page);
        const named_node_map = try page._factory.create(Attribute.NamedNodeMap{ ._list = attributes, ._element = self });
        gop.value_ptr.* = named_node_map;
    }
    return gop.value_ptr.*;
}

pub fn getStyle(self: *Element, page: *Page) !*CSSStyleProperties {
    const gop = try page._element_styles.getOrPut(page.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try CSSStyleProperties.init(self, false, page);
    }
    return gop.value_ptr.*;
}

pub fn getClassList(self: *Element, page: *Page) !*collections.DOMTokenList {
    const gop = try page._element_class_lists.getOrPut(page.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try page._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = "class",
        });
    }
    return gop.value_ptr.*;
}

pub fn getRelList(self: *Element, page: *Page) !*collections.DOMTokenList {
    const gop = try page._element_rel_lists.getOrPut(page.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try page._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = "rel",
        });
    }
    return gop.value_ptr.*;
}

pub fn getDataset(self: *Element, page: *Page) !*DOMStringMap {
    const gop = try page._element_datasets.getOrPut(page.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try page._factory.create(DOMStringMap{
            ._element = self,
        });
    }
    return gop.value_ptr.*;
}

pub fn replaceChildren(self: *Element, nodes: []const Node.NodeOrText, page: *Page) !void {
    page.domChanged();
    var parent = self.asNode();

    var it = parent.childrenIterator();
    while (it.next()) |child| {
        page.removeNode(parent, child, .{ .will_be_reconnected = false });
    }

    const parent_is_connected = parent.isConnected();
    for (nodes) |node_or_text| {
        var child_connected = false;
        const child = try node_or_text.toNode(page);
        if (child._parent) |previous_parent| {
            child_connected = child.isConnected();
            page.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected });
        }
        try page.appendNode(parent, child, .{ .child_already_connected = child_connected });
    }
}

pub fn remove(self: *Element, page: *Page) void {
    page.domChanged();
    const node = self.asNode();
    const parent = node._parent orelse return;
    page.removeNode(parent, node, .{ .will_be_reconnected = false });
}

pub fn focus(self: *Element, page: *Page) !void {
    const Event = @import("Event.zig");

    if (page.document._active_element) |old| {
        if (old == self) {
            return;
        }

        const blur_event = try Event.initTrusted("blur", null, page);
        try page._event_manager.dispatch(old.asEventTarget(), blur_event);
    }

    if (self.asNode().isConnected()) {
        page.document._active_element = self;
    }

    const focus_event = try Event.initTrusted("focus", null, page);
    try page._event_manager.dispatch(self.asEventTarget(), focus_event);
}

pub fn blur(self: *Element, page: *Page) !void {
    if (page.document._active_element != self) return;

    page.document._active_element = null;

    const Event = @import("Event.zig");
    const blur_event = try Event.initTrusted("blur", null, page);
    try page._event_manager.dispatch(self.asEventTarget(), blur_event);
}

pub fn getChildren(self: *Element, page: *Page) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, page);
}

pub fn append(self: *Element, nodes: []const Node.NodeOrText, page: *Page) !void {
    const parent = self.asNode();
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.appendChild(child, page);
    }
}

pub fn prepend(self: *Element, nodes: []const Node.NodeOrText, page: *Page) !void {
    const parent = self.asNode();
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(page);
        _ = try parent.insertBefore(child, parent.firstChild(), page);
    }
}

pub fn before(self: *Element, nodes: []const Node.NodeOrText, page: *Page) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.insertBefore(child, node, page);
    }
}

pub fn after(self: *Element, nodes: []const Node.NodeOrText, page: *Page) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const next = node.nextSibling();

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.insertBefore(child, next, page);
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

pub fn matches(self: *Element, selector: []const u8, page: *Page) !bool {
    return Selector.matches(self, selector, page);
}

pub fn querySelector(self: *Element, selector: []const u8, page: *Page) !?*Element {
    return Selector.querySelector(self.asNode(), selector, page);
}

pub fn querySelectorAll(self: *Element, input: []const u8, page: *Page) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, page);
}

pub fn getAnimations(_: *const Element) []*Animation {
    return &.{};
}

pub fn animate(_: *Element, _: ?js.Object, _: ?js.Object, page: *Page) !*Animation {
    return Animation.init(page);
}

pub fn closest(self: *Element, selector: []const u8, page: *Page) !?*Element {
    if (selector.len == 0) {
        return error.SyntaxError;
    }

    var current: ?*Element = self;
    while (current) |el| {
        if (try el.matches(selector, page)) {
            return el;
        }

        const parent = el._proto._parent orelse break;

        if (parent.is(ShadowRoot) != null) {
            break;
        }

        current = parent.is(Element);
    }
    return null;
}

pub fn parentElement(self: *Element) ?*Element {
    return self._proto.parentElement();
}

pub fn checkVisibility(self: *Element, page: *Page) !bool {
    var current: ?*Element = self;

    while (current) |el| {
        const style = try el.getStyle(page);
        const display = style.asCSSStyleDeclaration().getPropertyValue("display", page);
        if (std.mem.eql(u8, display, "none")) {
            return false;
        }
        current = el.parentElement();
    }

    return true;
}

fn getElementDimensions(self: *Element, page: *Page) !struct { width: f64, height: f64 } {
    const style = try self.getStyle(page);
    const decl = style.asCSSStyleDeclaration();
    var width = CSS.parseDimension(decl.getPropertyValue("width", page)) orelse 5.0;
    var height = CSS.parseDimension(decl.getPropertyValue("height", page)) orelse 5.0;

    if (width == 5.0 or height == 5.0) {
        const tag = self.getTag();

        // Root containers get large default size to contain descendant positions.
        // With calculateDocumentPosition using linear depth scaling (100px per level),
        // even very deep trees (100 levels) stay within 10,000px.
        // 100M pixels is plausible for very long documents.
        if (tag == .html or tag == .body) {
            if (width == 5.0) width = 1920.0;
            if (height == 5.0) height = 100_000_000.0;
        } else if (tag == .img or tag == .iframe) {
            if (self.getAttributeSafe("width")) |w| {
                width = std.fmt.parseFloat(f64, w) catch width;
            }
            if (self.getAttributeSafe("height")) |h| {
                height = std.fmt.parseFloat(f64, h) catch height;
            }
        }
    }

    return .{ .width = width, .height = height };
}

pub fn getClientWidth(self: *Element, page: *Page) !f64 {
    if (!try self.checkVisibility(page)) {
        return 0.0;
    }
    const dims = try self.getElementDimensions(page);
    return dims.width;
}

pub fn getClientHeight(self: *Element, page: *Page) !f64 {
    if (!try self.checkVisibility(page)) {
        return 0.0;
    }
    const dims = try self.getElementDimensions(page);
    return dims.height;
}

pub fn getBoundingClientRect(self: *Element, page: *Page) !*DOMRect {
    if (!try self.checkVisibility(page)) {
        return page._factory.create(DOMRect{
            ._x = 0.0,
            ._y = 0.0,
            ._width = 0.0,
            ._height = 0.0,
        });
    }

    const y = calculateDocumentPosition(self.asNode());
    const dims = try self.getElementDimensions(page);

    // Use sibling position for x coordinate to ensure siblings have different x values
    const x = calculateSiblingPosition(self.asNode());

    return page._factory.create(DOMRect{
        ._x = x,
        ._y = y,
        ._width = dims.width,
        ._height = dims.height,
    });
}

pub fn getClientRects(self: *Element, page: *Page) ![]DOMRect {
    if (!try self.checkVisibility(page)) {
        return &.{};
    }
    const ptr = try self.getBoundingClientRect(page);
    return ptr[0..1];
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

// Calculates horizontal position using the same approach as y,
// just scaled differently for visual distinction
fn calculateSiblingPosition(node: *Node) f64 {
    var position: f64 = 0.0;
    var current = node;

    // Walk up to root, counting preceding nodes (same as y)
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

const GetElementsByTagNameResult = union(enum) {
    tag: collections.NodeLive(.tag),
    tag_name: collections.NodeLive(.tag_name),
    all_elements: collections.NodeLive(.all_elements),
};
pub fn getElementsByTagName(self: *Element, tag_name: []const u8, page: *Page) !GetElementsByTagNameResult {
    if (tag_name.len > 256) {
        // 256 seems generous.
        return error.InvalidTagName;
    }

    if (std.mem.eql(u8, tag_name, "*")) {
        return .{
            .all_elements = collections.NodeLive(.all_elements).init(self.asNode(), {}, page),
        };
    }

    const lower = std.ascii.lowerString(&page.buf, tag_name);
    if (Tag.parseForMatch(lower)) |known| {
        // optimized for known tag names
        return .{
            .tag = collections.NodeLive(.tag).init(self.asNode(), known, page),
        };
    }

    const arena = page.arena;
    const filter = try String.init(arena, lower, .{});
    return .{ .tag_name = collections.NodeLive(.tag_name).init(self.asNode(), filter, page) };
}

pub fn getElementsByClassName(self: *Element, class_name: []const u8, page: *Page) !collections.NodeLive(.class_name) {
    const arena = page.arena;

    // Parse space-separated class names
    var class_names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, class_name, &std.ascii.whitespace);
    while (it.next()) |name| {
        try class_names.append(arena, try page.dupeString(name));
    }

    return collections.NodeLive(.class_name).init(self.asNode(), class_names.items, page);
}

pub fn clone(self: *Element, deep: bool, page: *Page) !*Node {
    const tag_name = self.getTagNameDump();
    const node = try page.createElementNS(self._namespace, tag_name, self._attributes);

    // Allow element-specific types to copy their runtime state
    _ = Element.Build.call(node.as(Element), "cloned", .{ self, node.as(Element), page }) catch |err| {
        log.err(.dom, "element.clone.failed", .{ .err = err });
    };

    if (deep) {
        var child_it = self.asNode().childrenIterator();
        while (child_it.next()) |child| {
            const cloned_child = try child.cloneNode(true, page);
            // We pass `true` to `child_already_connected` as a hacky optimization
            // We _know_ this child isn't connected (Becasue the parent isn't connected)
            // setting this to `true` skips all connection checks and just assumes t
            try page.appendNode(node, cloned_child, .{ .child_already_connected = true });
        }
    }

    return node;
}

pub fn scrollIntoViewIfNeeded(_: *const Element, center_if_needed: ?bool) void {
    _ = center_if_needed;
}

pub fn format(self: *Element, writer: *std.Io.Writer) !void {
    try writer.writeByte('<');
    try writer.writeAll(self.getTagNameDump());

    if (self._attributes) |attributes| {
        var it = attributes.iterator();
        while (it.next()) |attr| {
            try writer.print(" {f}", .{attr});
        }
    }
    try writer.writeByte('>');
}

fn upperTagName(tag_name: *String, buf: []u8) []const u8 {
    if (tag_name.len > buf.len) {
        log.info(.dom, "tag.long.name", .{ .name = tag_name.str() });
        return tag_name.str();
    }
    const tag = tag_name.str();
    // If the tag_name has a prefix, we must uppercase only the suffix part.
    // example: te:st should be returned as te:ST.
    if (std.mem.indexOfPos(u8, tag, 0, ":")) |pos| {
        @memcpy(buf[0 .. pos + 1], tag[0 .. pos + 1]);
        _ = std.ascii.upperString(buf[pos..tag.len], tag[pos..tag.len]);
        return buf[0..tag.len];
    }
    return std.ascii.upperString(buf, tag);
}

pub fn getTag(self: *const Element) Tag {
    return switch (self._type) {
        .html => |he| switch (he._type) {
            .anchor => .anchor,
            .area => .area,
            .base => .base,
            .div => .div,
            .embed => .embed,
            .form => .form,
            .p => .p,
            .custom => .custom,
            .data => .data,
            .datalist => .datalist,
            .dialog => .dialog,
            .directory => .unknown,
            .iframe => .iframe,
            .img => .img,
            .br => .br,
            .button => .button,
            .canvas => .canvas,
            .fieldset => .fieldset,
            .font => .unknown,
            .heading => |h| h._tag,
            .label => .unknown,
            .legend => .unknown,
            .li => .li,
            .map => .unknown,
            .ul => .ul,
            .ol => .ol,
            .object => .unknown,
            .optgroup => .optgroup,
            .output => .unknown,
            .param => .unknown,
            .pre => .unknown,
            .generic => |g| g._tag,
            .media => |m| switch (m._type) {
                .audio => .audio,
                .video => .video,
                .generic => .media,
            },
            .meter => .meter,
            .mod => |m| m._tag,
            .progress => .progress,
            .quote => |q| q._tag,
            .script => .script,
            .select => .select,
            .slot => .slot,
            .source => .unknown,
            .span => .span,
            .option => .option,
            .table => .table,
            .table_caption => .caption,
            .table_cell => |tc| tc._tag,
            .table_col => |tc| tc._tag,
            .table_row => .tr,
            .table_section => |ts| ts._tag,
            .template => .template,
            .textarea => .textarea,
            .time => .time,
            .track => .unknown,
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
        },
        .svg => |se| switch (se._type) {
            .svg => .svg,
            .generic => |g| g._tag,
        },
    };
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
    dl,
    dt,
    embed,
    ellipse,
    em,
    fieldset,
    figure,
    form,
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
    li,
    line,
    link,
    main,
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
    polygon,
    polyline,
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
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Element);

    pub const Meta = struct {
        pub const name = "Element";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const tagName = bridge.accessor(_tagName, null, .{});
    fn _tagName(self: *Element, page: *Page) []const u8 {
        return self.getTagNameSpec(&page.buf);
    }
    pub const namespaceURI = bridge.accessor(Element.getNamespaceURI, null, .{});

    pub const innerText = bridge.accessor(_innerText, Element.setInnerText, .{});
    fn _innerText(self: *Element, page: *const Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getInnerText(&buf.writer);
        return buf.written();
    }

    pub const outerHTML = bridge.accessor(_outerHTML, Element.setOuterHTML, .{});
    fn _outerHTML(self: *Element, page: *Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getOuterHTML(&buf.writer, page);
        return buf.written();
    }

    pub const innerHTML = bridge.accessor(_innerHTML, Element.setInnerHTML, .{});
    fn _innerHTML(self: *Element, page: *Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getInnerHTML(&buf.writer, page);
        return buf.written();
    }

    pub const prefix = bridge.accessor(_prefix, null, .{});
    fn _prefix(self: *Element) ?[]const u8 {
        const name = self.getTagNameLower();
        if (std.mem.indexOfPos(u8, name, 0, ":")) |pos| {
            return name[0..pos];
        }

        return null;
    }

    pub const localName = bridge.accessor(Element.getLocalName, null, .{});
    pub const id = bridge.accessor(Element.getId, Element.setId, .{});
    pub const slot = bridge.accessor(Element.getSlot, Element.setSlot, .{});
    pub const dir = bridge.accessor(Element.getDir, Element.setDir, .{});
    pub const className = bridge.accessor(Element.getClassName, Element.setClassName, .{});
    pub const classList = bridge.accessor(Element.getClassList, null, .{});
    pub const dataset = bridge.accessor(Element.getDataset, null, .{});
    pub const style = bridge.accessor(Element.getStyle, null, .{});
    pub const attributes = bridge.accessor(Element.getAttributeNamedNodeMap, null, .{});
    pub const hasAttribute = bridge.function(Element.hasAttribute, .{});
    pub const hasAttributes = bridge.function(Element.hasAttributes, .{});
    pub const getAttribute = bridge.function(Element.getAttribute, .{});
    pub const getAttributeNode = bridge.function(Element.getAttributeNode, .{});
    pub const setAttribute = bridge.function(Element.setAttribute, .{ .dom_exception = true });
    pub const setAttributeNode = bridge.function(Element.setAttributeNode, .{});
    pub const removeAttribute = bridge.function(Element.removeAttribute, .{});
    pub const toggleAttribute = bridge.function(Element.toggleAttribute, .{ .dom_exception = true });
    pub const getAttributeNames = bridge.function(Element.getAttributeNames, .{});
    pub const removeAttributeNode = bridge.function(Element.removeAttributeNode, .{ .dom_exception = true });
    pub const shadowRoot = bridge.accessor(Element.getShadowRoot, null, .{});
    pub const assignedSlot = bridge.accessor(Element.getAssignedSlot, null, .{});
    pub const attachShadow = bridge.function(_attachShadow, .{ .dom_exception = true });
    pub const insertAdjacentHTML = bridge.function(Element.insertAdjacentHTML, .{ .dom_exception = true });
    pub const insertAdjacentElement = bridge.function(Element.insertAdjacentElement, .{ .dom_exception = true });
    pub const insertAdjacentText = bridge.function(Element.insertAdjacentText, .{ .dom_exception = true });

    const ShadowRootInit = struct {
        mode: []const u8,
    };
    fn _attachShadow(self: *Element, init: ShadowRootInit, page: *Page) !*ShadowRoot {
        return self.attachShadow(init.mode, page);
    }
    pub const replaceChildren = bridge.function(Element.replaceChildren, .{});
    pub const remove = bridge.function(Element.remove, .{});
    pub const append = bridge.function(Element.append, .{});
    pub const prepend = bridge.function(Element.prepend, .{});
    pub const before = bridge.function(Element.before, .{});
    pub const after = bridge.function(Element.after, .{});
    pub const firstElementChild = bridge.accessor(Element.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Element.lastElementChild, null, .{});
    pub const nextElementSibling = bridge.accessor(Element.nextElementSibling, null, .{});
    pub const previousElementSibling = bridge.accessor(Element.previousElementSibling, null, .{});
    pub const childElementCount = bridge.accessor(Element.getChildElementCount, null, .{});
    pub const matches = bridge.function(Element.matches, .{ .dom_exception = true });
    pub const querySelector = bridge.function(Element.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(Element.querySelectorAll, .{ .dom_exception = true });
    pub const closest = bridge.function(Element.closest, .{ .dom_exception = true });
    pub const getAnimations = bridge.function(Element.getAnimations, .{});
    pub const animate = bridge.function(Element.animate, .{});
    pub const checkVisibility = bridge.function(Element.checkVisibility, .{});
    pub const clientWidth = bridge.accessor(Element.getClientWidth, null, .{});
    pub const clientHeight = bridge.accessor(Element.getClientHeight, null, .{});
    pub const getClientRects = bridge.function(Element.getClientRects, .{});
    pub const getBoundingClientRect = bridge.function(Element.getBoundingClientRect, .{});
    pub const getElementsByTagName = bridge.function(Element.getElementsByTagName, .{});
    pub const getElementsByClassName = bridge.function(Element.getElementsByClassName, .{});
    pub const children = bridge.accessor(Element.getChildren, null, .{});
    pub const focus = bridge.function(Element.focus, .{});
    pub const blur = bridge.function(Element.blur, .{});
    pub const scrollIntoViewIfNeeded = bridge.function(Element.scrollIntoViewIfNeeded, .{});
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the Element itself.
    pub fn call(self: *const Element, comptime func_name: []const u8, args: anytype) !bool {
        inline for (@typeInfo(Element.Type).@"union".fields) |f| {
            if (@field(Element.Type, f.name) == self._type) {
                // The inner type implements this function. Call it and we're done.
                const S = reflect.Struct(f.type);
                if (@hasDecl(S, "Build")) {
                    if (@hasDecl(S.Build, "call")) {
                        const sub = @field(self._type, f.name);
                        return S.Build.call(sub, func_name, args);
                    }

                    // The inner type implements this function. Call it and we're done.
                    if (@hasDecl(f.type, func_name)) {
                        return @call(.auto, @field(f.type, func_name), args);
                    }
                }
            }
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
