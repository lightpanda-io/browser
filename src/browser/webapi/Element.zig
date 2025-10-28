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

pub const Svg = @import("element/Svg.zig");
pub const Html = @import("element/Html.zig");

const Element = @This();

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
_style: ?*CSSStyleProperties = null,
_class_list: ?*collections.DOMTokenList = null,

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
                .div => "div",
                .form => "form",
                .generic => |e| e._tag_name.str(),
                .heading => |e| e._tag_name.str(),
                .head => "head",
                .html => "html",
                .hr => "hr",
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
                .div => "DIV",
                .form => "FORM",
                .generic => |e| upperTagName(&e._tag_name, buf),
                .heading => |e| upperTagName(&e._tag_name, buf),
                .head => "HEAD",
                .html => "HTML",
                .hr => "HR",
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
    return self._style orelse blk: {
        const s = try CSSStyleProperties.init(self, page);
        self._style = s;
        break :blk s;
    };
}

pub fn getClassList(self: *Element, page: *Page) !*collections.DOMTokenList {
    return self._class_list orelse blk: {
        const cl = try page._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = "class",
        });
        self._class_list = cl;
        break :blk cl;
    };
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
    const node = self.asNode();
    const parent = node._parent orelse return;
    page.removeNode(parent, node, .{ .will_be_reconnected = false });
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

pub fn querySelector(self: *Element, selector: []const u8, page: *Page) !?*Element {
    return Selector.querySelector(self.asNode(), selector, page);
}

pub fn querySelectorAll(self: *Element, input: []const u8, page: *Page) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, page);
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
        // optimized for known tag names, comparis
        return .{
            .tag = try collections.NodeLive(.tag).init(null, self.asNode(), known, page),
        };
    }

    const arena = page.arena;
    const filter = try String.init(arena, lower, .{});
    return .{ .tag_name = try collections.NodeLive(.tag_name).init(arena, self.asNode(), filter, page) };
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
        pub var class_index: u16 = 0;
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
    pub const style = bridge.accessor(Element.getStyle, null, .{});
    pub const attributes = bridge.accessor(Element.getAttributeNamedNodeMap, null, .{});
    pub const getAttribute = bridge.function(Element.getAttribute, .{});
    pub const getAttributeNode = bridge.function(Element.getAttributeNode, .{});
    pub const setAttribute = bridge.function(Element.setAttribute, .{});
    pub const setAttributeNode = bridge.function(Element.setAttributeNode, .{});
    pub const removeAttribute = bridge.function(Element.removeAttribute, .{});
    pub const getAttributeNames = bridge.function(Element.getAttributeNames, .{});
    pub const removeAttributeNode = bridge.function(Element.removeAttributeNode, .{ .dom_exception = true });
    pub const replaceChildren = bridge.function(Element.replaceChildren, .{});
    pub const remove = bridge.function(Element.remove, .{});
    pub const append = bridge.function(Element.append, .{});
    pub const prepend = bridge.function(Element.prepend, .{});
    pub const firstElementChild = bridge.accessor(Element.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Element.lastElementChild, null, .{});
    pub const nextElementSibling = bridge.accessor(Element.nextElementSibling, null, .{});
    pub const previousElementSibling = bridge.accessor(Element.previousElementSibling, null, .{});
    pub const childElementCount = bridge.accessor(Element.getChildElementCount, null, .{});
    pub const querySelector = bridge.function(Element.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(Element.querySelectorAll, .{ .dom_exception = true });
    pub const getElementsByTagName = bridge.function(Element.getElementsByTagName, .{});
    pub const getElementsByClassName = bridge.function(Element.getElementsByClassName, .{});
    pub const children = bridge.accessor(Element.getChildren, null, .{});
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
