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
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
pub const Attribute = @import("element/Attribute.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");
pub const DOMStringMap = @import("element/DOMStringMap.zig");
const DOMRect = @import("DOMRect.zig");
const css = @import("css.zig");
const ShadowRoot = @import("ShadowRoot.zig");

pub const Svg = @import("element/Svg.zig");
pub const Html = @import("element/Html.zig");

const Element = @This();

pub const DatasetLookup = std.AutoHashMapUnmanaged(*Element, *DOMStringMap);
pub const StyleLookup = std.AutoHashMapUnmanaged(*Element, *CSSStyleProperties);
pub const ClassListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const ShadowRootLookup = std.AutoHashMapUnmanaged(*Element, *ShadowRoot);

pub const Namespace = enum(u8) {
    html,
    svg,
    mathml,
    xml,

    pub fn toUri(self: Namespace) []const u8 {
        return switch (self) {
            .html => "http://www.w3.org/1999/xhtml",
            .svg => "http://www.w3.org/2000/svg",
            .mathml => "http://www.w3.org/1998/Math/MathML",
            .xml => "http://www.w3.org/XML/1998/namespace",
        };
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
            if (T == *Html) {
                return el;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.")) {
                return el.is(T);
            }
        },
        .svg => |svg| {
            if (T == *Svg) {
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

pub fn className(self: *const Element) []const u8 {
    return switch (self._type) {
        inline else => |c| return c.className(),
    };
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
                .body => "body",
                .br => "br",
                .button => "button",
                .custom => |e| e._tag_name.str(),
                .dialog => "dialog",
                .div => "div",
                .form => "form",
                .generic => |e| e._tag_name.str(),
                .heading => |e| e._tag_name.str(),
                .head => "head",
                .html => "html",
                .hr => "hr",
                .iframe => "iframe",
                .img => "img",
                .input => "input",
                .li => "li",
                .link => "link",
                .meta => "meta",
                .ol => "ol",
                .option => "option",
                .p => "p",
                .script => "script",
                .select => "select",
                .style => "style",
                .template => "template",
                .text_area => "textarea",
                .title => "title",
                .ul => "ul",
                .unknown => |e| e._tag_name.str(),
            },
        },
        .svg => |svg| return svg._tag_name.str(),
    }
}

pub fn getTagNameSpec(self: *const Element, buf: []u8) []const u8 {
    switch (self._type) {
        .html => |he| switch (he._type) {
            .custom => |e| {
                @branchHint(.unlikely);
                return upperTagName(&e._tag_name, buf);
            },
            else => return switch (he._type) {
                .anchor => "A",
                .body => "BODY",
                .br => "BR",
                .button => "BUTTON",
                .custom => |e| upperTagName(&e._tag_name, buf),
                .dialog => "DIALOG",
                .div => "DIV",
                .form => "FORM",
                .generic => |e| upperTagName(&e._tag_name, buf),
                .heading => |e| upperTagName(&e._tag_name, buf),
                .head => "HEAD",
                .html => "HTML",
                .hr => "HR",
                .iframe => "IFRAME",
                .img => "IMG",
                .input => "INPUT",
                .li => "LI",
                .link => "LINK",
                .meta => "META",
                .ol => "OL",
                .option => "OPTION",
                .p => "P",
                .script => "SCRIPT",
                .select => "SELECT",
                .style => "STYLE",
                .template => "TEMPLATE",
                .text_area => "TEXTAREA",
                .title => "TITLE",
                .ul => "UL",
                .unknown => |e| switch (self._namespace) {
                    .html => upperTagName(&e._tag_name, buf),
                    .svg, .xml, .mathml => return e._tag_name.str(),
                },
            },
        },
        .svg => |svg| return svg._tag_name.str(),
    }
}

pub fn getTagNameDump(self: *const Element) []const u8 {
    switch (self._type) {
        .html => return self.getTagNameLower(),
        .svg => |svg| return svg._tag_name.str(),
    }
}

pub fn getNamespaceURI(self: *const Element) []const u8 {
    return self._namespace.toUri();
}

pub fn getInnerText(self: *Element, writer: *std.Io.Writer) !void {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        try child.getTextContent(writer);
    }
}

pub fn getOuterHTML(self: *Element, writer: *std.Io.Writer) !void {
    const dump = @import("../dump.zig");
    return dump.deep(self.asNode(), .{}, writer);
}

pub fn getInnerHTML(self: *Element, writer: *std.Io.Writer) !void {
    const dump = @import("../dump.zig");
    return dump.children(self.asNode(), .{}, writer);
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

pub fn getClassName(self: *const Element) []const u8 {
    return self.getAttributeSafe("class") orelse "";
}

pub fn setClassName(self: *Element, value: []const u8, page: *Page) !void {
    return self.setAttributeSafe("class", value, page);
}

pub fn attributeIterator(self: *Element) Attribute.Iterator {
    const attributes = self._attributes orelse return .{};
    return attributes.iterator(self);
}

pub fn getAttribute(self: *const Element, name: []const u8, page: *Page) !?[]const u8 {
    const attributes = self._attributes orelse return null;
    return attributes.get(name, page);
}

pub fn hasAttribute(self: *const Element, name: []const u8, page: *Page) !bool {
    const attributes = self._attributes orelse return false;
    const value = try attributes.get(name, page);
    return value != null;
}

pub fn getAttributeNode(self: *Element, name: []const u8, page: *Page) !?*Attribute {
    const attributes = self._attributes orelse return null;
    return attributes.getAttribute(name, self, page);
}

pub fn getAttributeSafe(self: *const Element, name: []const u8) ?[]const u8 {
    const attributes = self._attributes orelse return null;
    return attributes.getSafe(name);
}

pub fn setAttribute(self: *Element, name: []const u8, value: []const u8, page: *Page) !void {
    const attributes = try self.getOrCreateAttributeList(page);
    _ = try attributes.put(name, value, self, page);
}

pub fn setAttributeSafe(self: *Element, name: []const u8, value: []const u8, page: *Page) !void {
    const attributes = try self.getOrCreateAttributeList(page);
    _ = try attributes.putSafe(name, value, self, page);
}

fn getOrCreateAttributeList(self: *Element, page: *Page) !*Attribute.List {
    return self._attributes orelse {
        const a = try page.arena.create(Attribute.List);
        a.* = .{};
        self._attributes = a;
        return a;
    };
}

pub fn getShadowRoot(self: *Element, page: *Page) ?*ShadowRoot {
    const shadow_root = page._element_shadow_roots.get(self) orelse return null;
    if (shadow_root._mode == .closed) return null;
    return shadow_root;
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

pub fn setAttributeNode(self: *Element, attr: *Attribute, page: *Page) !?*Attribute {
    if (attr._element) |el| {
        if (el == self) {
            return attr;
        }
        attr._element = null;
        _ = try el.removeAttributeNode(attr, page);
    }

    const attributes = self._attributes orelse blk: {
        const a = try page.arena.create(Attribute.List);
        a.* = .{};
        self._attributes = a;
        break :blk a;
    };
    return attributes.putAttribute(attr, self, page);
}

pub fn removeAttribute(self: *Element, name: []const u8, page: *Page) !void {
    const attributes = self._attributes orelse return;
    return attributes.delete(name, self, page);
}

pub fn toggleAttribute(self: *Element, name: []const u8, force: ?bool, page: *Page) !bool {
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
        gop.value_ptr.* = try CSSStyleProperties.init(self, page);
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
        if (old == self) return;

        const blur_event = try Event.init("blur", null, page);
        try page._event_manager.dispatch(old.asEventTarget(), blur_event);
    }

    page.document._active_element = self;

    const focus_event = try Event.init("focus", null, page);
    try page._event_manager.dispatch(self.asEventTarget(), focus_event);
}

pub fn blur(self: *Element, page: *Page) !void {
    if (page.document._active_element != self) return;

    page.document._active_element = null;

    const Event = @import("Event.zig");
    const blur_event = try Event.init("blur", null, page);
    try page._event_manager.dispatch(self.asEventTarget(), blur_event);
}

pub fn getChildren(self: *Element, page: *Page) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(null, self.asNode(), {}, page);
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

pub fn getBoundingClientRect(self: *Element, page: *Page) !*DOMRect {
    const is_visible = try self.checkVisibility(page);
    if (!is_visible) {
        return page._factory.create(DOMRect{
            ._x = 0.0,
            ._y = 0.0,
            ._width = 0.0,
            ._height = 0.0,
            ._top = 0.0,
            ._right = 0.0,
            ._bottom = 0.0,
            ._left = 0.0,
        });
    }

    const y = calculateDocumentPosition(self.asNode());

    var width: f64 = 1.0;
    var height: f64 = 1.0;

    const style = try self.getStyle(page);
    const decl = style.asCSSStyleDeclaration();
    width = css.parseDimension(decl.getPropertyValue("width", page)) orelse 1.0;
    height = css.parseDimension(decl.getPropertyValue("height", page)) orelse 1.0;

    if (width == 1.0 or height == 1.0) {
        const tag = self.getTag();
        if (tag == .img or tag == .iframe) {
            if (self.getAttributeSafe("width")) |w| {
                width = std.fmt.parseFloat(f64, w) catch width;
            }
            if (self.getAttributeSafe("height")) |h| {
                height = std.fmt.parseFloat(f64, h) catch height;
            }
        }
    }

    const x: f64 = 0.0;
    const top = y;
    const left = x;
    const right = x + width;
    const bottom = y + height;

    return page._factory.create(DOMRect{
        ._x = x,
        ._y = y,
        ._width = width,
        ._height = height,
        ._top = top,
        ._right = right,
        ._bottom = bottom,
        ._left = left,
    });
}

// Calculates a pseudo-position in the document using an efficient heuristic.
//
// Instead of walking the entire DOM tree (which would be O(total_nodes)), this
// function walks UP the tree counting previous siblings at each level. Each level
// uses exponential weighting (1000x per depth level) to preserve document order.
//
// This gives O(depth * avg_siblings) complexity while maintaining relative positioning
// that's useful for scraping and understanding element flow in the document.
//
// Example:
//   <body>              → position 0
//     <div>             → position 0 (0 siblings at level 1)
//       <span></span>   → position 0 (0 siblings at level 2)
//       <span></span>   → position 1 (1 sibling at level 2)
//     </div>
//     <div>             → position 1000 (1 sibling at level 1, weighted by 1000)
//       <p></p>         → position 1000 (0 siblings at level 2, parent has 1000)
//     </div>
//   </body>
//
// Trade-offs:
// - Much faster than full tree-walking for deep/large DOMs
// - Positions reflect document order and parent-child relationships
// - Not pixel-accurate, but sufficient for 1x1 layout heuristics
fn calculateDocumentPosition(node: *Node) f64 {
    var position: f64 = 0.0;
    var multiplier: f64 = 1.0;
    var current = node;

    while (current.parentNode()) |parent| {
        var count: f64 = 0.0;
        var sibling = parent.firstChild();
        while (sibling) |s| {
            if (s == current) break;
            count += 1.0;
            sibling = s.nextSibling();
        }

        position += count * multiplier;
        multiplier *= 1000.0;
        current = parent;
    }

    return position;
}

const GetElementsByTagNameResult = union(enum) {
    tag: collections.NodeLive(.tag),
    tag_name: collections.NodeLive(.tag_name),
};
pub fn getElementsByTagName(self: *Element, tag_name: []const u8, page: *Page) !GetElementsByTagNameResult {
    if (tag_name.len > 256) {
        // 256 seems generous.
        return error.InvalidTagName;
    }

    const lower = std.ascii.lowerString(&page.buf, tag_name);
    if (Tag.parseForMatch(lower)) |known| {
        // optimized for known tag names
        return .{
            .tag = collections.NodeLive(.tag).init(null, self.asNode(), known, page),
        };
    }

    const arena = page.arena;
    const filter = try String.init(arena, lower, .{});
    return .{ .tag_name = collections.NodeLive(.tag_name).init(arena, self.asNode(), filter, page) };
}

pub fn getElementsByClassName(self: *Element, class_name: []const u8, page: *Page) !collections.NodeLive(.class_name) {
    const arena = page.arena;
    const filter = try arena.dupe(u8, class_name);
    return collections.NodeLive(.class_name).init(arena, self.asNode(), filter, page);
}

pub fn cloneElement(self: *Element, deep: bool, page: *Page) !*Node {
    const tag_name = self.getTagNameDump();
    const namespace_uri = self.getNamespaceURI();

    const node = try page.createElement(namespace_uri, tag_name, self._attributes);

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
    return std.ascii.upperString(buf, tag_name.str());
}

pub fn getTag(self: *const Element) Tag {
    return switch (self._type) {
        .html => |he| switch (he._type) {
            .anchor => .anchor,
            .div => .div,
            .form => .form,
            .p => .p,
            .custom => .custom,
            .dialog => .dialog,
            .iframe => .iframe,
            .img => .img,
            .br => .br,
            .button => .button,
            .heading => |h| h._tag,
            .li => .li,
            .ul => .ul,
            .ol => .ol,
            .generic => |g| g._tag,
            .script => .script,
            .select => .select,
            .option => .option,
            .template => .template,
            .text_area => .textarea,
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
    anchor,
    b,
    body,
    br,
    button,
    circle,
    custom,
    dialog,
    div,
    ellipse,
    em,
    form,
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
    hr,
    html,
    i,
    iframe,
    img,
    input,
    li,
    line,
    link,
    main,
    meta,
    nav,
    ol,
    option,
    p,
    path,
    polygon,
    polyline,
    rect,
    script,
    select,
    span,
    strong,
    style,
    svg,
    text,
    template,
    textarea,
    title,
    ul,
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

    pub const innerText = bridge.accessor(_innerText, null, .{});
    fn _innerText(self: *Element, page: *const Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getInnerText(&buf.writer);
        return buf.written();
    }

    pub const outerHTML = bridge.accessor(_outerHTML, null, .{});
    fn _outerHTML(self: *Element, page: *Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getOuterHTML(&buf.writer);
        return buf.written();
    }

    pub const innerHTML = bridge.accessor(_innerHTML, Element.setInnerHTML, .{});
    fn _innerHTML(self: *Element, page: *Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getInnerHTML(&buf.writer);
        return buf.written();
    }

    pub const id = bridge.accessor(Element.getId, Element.setId, .{});
    pub const className = bridge.accessor(Element.getClassName, Element.setClassName, .{});
    pub const classList = bridge.accessor(Element.getClassList, null, .{});
    pub const dataset = bridge.accessor(Element.getDataset, null, .{});
    pub const style = bridge.accessor(Element.getStyle, null, .{});
    pub const attributes = bridge.accessor(Element.getAttributeNamedNodeMap, null, .{});
    pub const hasAttribute = bridge.function(Element.hasAttribute, .{});
    pub const getAttribute = bridge.function(Element.getAttribute, .{});
    pub const getAttributeNode = bridge.function(Element.getAttributeNode, .{});
    pub const setAttribute = bridge.function(Element.setAttribute, .{});
    pub const setAttributeNode = bridge.function(Element.setAttributeNode, .{});
    pub const removeAttribute = bridge.function(Element.removeAttribute, .{});
    pub const toggleAttribute = bridge.function(Element.toggleAttribute, .{});
    pub const getAttributeNames = bridge.function(Element.getAttributeNames, .{});
    pub const removeAttributeNode = bridge.function(Element.removeAttributeNode, .{ .dom_exception = true });
    pub const shadowRoot = bridge.accessor(Element.getShadowRoot, null, .{});
    pub const attachShadow = bridge.function(_attachShadow, .{ .dom_exception = true });

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
    pub const firstElementChild = bridge.accessor(Element.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Element.lastElementChild, null, .{});
    pub const nextElementSibling = bridge.accessor(Element.nextElementSibling, null, .{});
    pub const previousElementSibling = bridge.accessor(Element.previousElementSibling, null, .{});
    pub const childElementCount = bridge.accessor(Element.getChildElementCount, null, .{});
    pub const matches = bridge.function(Element.matches, .{ .dom_exception = true });
    pub const querySelector = bridge.function(Element.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(Element.querySelectorAll, .{ .dom_exception = true });
    pub const closest = bridge.function(Element.closest, .{ .dom_exception = true });
    pub const checkVisibility = bridge.function(Element.checkVisibility, .{});
    pub const getBoundingClientRect = bridge.function(Element.getBoundingClientRect, .{});
    pub const getElementsByTagName = bridge.function(Element.getElementsByTagName, .{});
    pub const getElementsByClassName = bridge.function(Element.getElementsByClassName, .{});
    pub const children = bridge.accessor(Element.getChildren, null, .{});
    pub const focus = bridge.function(Element.focus, .{});
    pub const blur = bridge.function(Element.blur, .{});
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
