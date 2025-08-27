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

const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

const css = @import("css.zig");
const log = @import("../../log.zig");
const dump = @import("../dump.zig");
const collection = @import("html_collection.zig");

const Node = @import("node.zig").Node;
const Walker = @import("walker.zig").WalkerDepthFirst;
const NodeList = @import("nodelist.zig").NodeList;
const HTMLElem = @import("../html/elements.zig");
const ShadowRoot = @import("../dom/shadow_root.zig").ShadowRoot;

const Animation = @import("Animation.zig");
const JsObject = @import("../env.zig").JsObject;

pub const Union = @import("../html/elements.zig").Union;

// WEB IDL https://dom.spec.whatwg.org/#element
pub const Element = struct {
    pub const Self = parser.Element;
    pub const prototype = *Node;
    pub const subtype = .node;

    pub const DOMRect = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        bottom: f64,
        right: f64,
        top: f64,
        left: f64,
    };

    pub fn toInterface(e: *parser.Element) !Union {
        return toInterfaceT(Union, e);
    }

    pub fn toInterfaceT(comptime T: type, e: *parser.Element) !T {
        const tagname = try parser.elementGetTagName(e) orelse {
            // If the owner's document is HTML, assume we have an HTMLElement.
            const doc = try parser.nodeOwnerDocument(parser.elementToNode(e));
            if (doc != null and !doc.?.is_html) {
                return .{ .HTMLElement = @as(*parser.ElementHTML, @ptrCast(e)) };
            }

            return .{ .Element = e };
        };

        // TODO SVGElement and MathML are not supported yet.

        const tag = parser.Tag.fromString(tagname) catch {
            // If the owner's document is HTML, assume we have an HTMLElement.
            const doc = try parser.nodeOwnerDocument(parser.elementToNode(e));
            if (doc != null and doc.?.is_html) {
                return .{ .HTMLElement = @as(*parser.ElementHTML, @ptrCast(e)) };
            }

            return .{ .Element = e };
        };

        return HTMLElem.toInterfaceFromTag(T, e, tag);
    }

    // JS funcs
    // --------

    pub fn get_namespaceURI(self: *parser.Element) !?[]const u8 {
        return try parser.nodeGetNamespace(parser.elementToNode(self));
    }

    pub fn get_prefix(self: *parser.Element) !?[]const u8 {
        return try parser.nodeGetPrefix(parser.elementToNode(self));
    }

    pub fn get_localName(self: *parser.Element) ![]const u8 {
        return try parser.nodeLocalName(parser.elementToNode(self));
    }

    pub fn get_tagName(self: *parser.Element) ![]const u8 {
        return try parser.nodeName(parser.elementToNode(self));
    }

    pub fn get_id(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "id") orelse "";
    }

    pub fn set_id(self: *parser.Element, id: []const u8) !void {
        return try parser.elementSetAttribute(self, "id", id);
    }

    pub fn get_className(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "class") orelse "";
    }

    pub fn set_className(self: *parser.Element, class: []const u8) !void {
        return try parser.elementSetAttribute(self, "class", class);
    }

    pub fn get_slot(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "slot") orelse "";
    }

    pub fn set_slot(self: *parser.Element, slot: []const u8) !void {
        return try parser.elementSetAttribute(self, "slot", slot);
    }

    pub fn get_classList(self: *parser.Element) !*parser.TokenList {
        return try parser.tokenListCreate(self, "class");
    }

    pub fn get_attributes(self: *parser.Element) !*parser.NamedNodeMap {
        // An element must have non-nil attributes.
        return try parser.nodeGetAttributes(parser.elementToNode(self)) orelse unreachable;
    }

    pub fn get_innerHTML(self: *parser.Element, page: *Page) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(page.call_arena);
        try dump.writeChildren(parser.elementToNode(self), .{}, &aw.writer);
        return aw.written();
    }

    pub fn get_outerHTML(self: *parser.Element, page: *Page) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(page.call_arena);
        try dump.writeNode(parser.elementToNode(self), .{}, &aw.writer);
        return aw.written();
    }

    pub fn set_innerHTML(self: *parser.Element, str: []const u8, page: *Page) !void {
        const node = parser.elementToNode(self);
        const doc = try parser.nodeOwnerDocument(node) orelse return parser.DOMError.WrongDocument;
        // parse the fragment
        const fragment = try parser.documentParseFragmentFromStr(doc, str);

        // remove existing children
        try Node.removeChildren(node);

        const fragment_node = parser.documentFragmentToNode(fragment);

        // I'm not sure what the exact behavior is supposed to be. Initially,
        // we were only copying the body of the document fragment. But it seems
        // like head elements should be copied too. Specifically, some sites
        // create script tags via innerHTML, which we need to capture.
        // If you play with this in a browser, you should notice that the
        // behavior is different depending on whether you're in a blank page
        // or an actual document. In a blank page, something like:
        //    x.innerHTML = '<script></script>';
        // does _not_ create an empty script, but in a real page, it does. Weird.
        const html = try parser.nodeFirstChild(fragment_node) orelse return;
        const head = try parser.nodeFirstChild(html) orelse return;
        const body = try parser.nodeNextSibling(head) orelse return;

        if (try parser.elementTag(self) == .template) {
            // HTMLElementTemplate is special. We don't append these as children
            // of the template, but instead set its content as the body of the
            // fragment. Simpler to do this by copying the body children into
            // a new fragment
            const clean = try parser.documentCreateDocumentFragment(doc);
            const children = try parser.nodeGetChildNodes(body);
            const ln = try parser.nodeListLength(children);
            for (0..ln) |_| {
                // always index 0, because nodeAppendChild moves the node out of
                // the nodeList and into the new tree
                const child = try parser.nodeListItem(children, 0) orelse continue;
                _ = try parser.nodeAppendChild(@ptrCast(@alignCast(clean)), child);
            }

            const state = try page.getOrCreateNodeState(node);
            state.template_content = clean;
            return;
        }

        // For any node other than a template, we copy the head and body elements
        // as child nodes of the element
        {
            // First, copy some of the head element
            const children = try parser.nodeGetChildNodes(head);
            const ln = try parser.nodeListLength(children);
            for (0..ln) |_| {
                // always index 0, because nodeAppendChild moves the node out of
                // the nodeList and into the new tree
                const child = try parser.nodeListItem(children, 0) orelse continue;
                _ = try parser.nodeAppendChild(node, child);
            }
        }

        {
            const children = try parser.nodeGetChildNodes(body);
            const ln = try parser.nodeListLength(children);
            for (0..ln) |_| {
                // always index 0, because nodeAppendChild moves the node out of
                // the nodeList and into the new tree
                const child = try parser.nodeListItem(children, 0) orelse continue;
                _ = try parser.nodeAppendChild(node, child);
            }
        }
    }

    // The closest() method of the Element interface traverses the element and its parents (heading toward the document root) until it finds a node that matches the specified CSS selector.
    // Returns the closest ancestor Element or itself, which matches the selectors. If there are no such element, null.
    pub fn _closest(self: *parser.Element, selector: []const u8, page: *Page) !?*parser.Element {
        const cssParse = @import("../css/css.zig").parse;
        const CssNodeWrap = @import("../css/libdom.zig").Node;
        const select = try cssParse(page.call_arena, selector, .{});

        var current: CssNodeWrap = .{ .node = parser.elementToNode(self) };
        while (true) {
            if (try select.match(current)) {
                if (!current.isElement()) {
                    log.err(.browser, "closest invalid type", .{ .type = try current.tag() });
                    return null;
                }
                return parser.nodeToElement(current.node);
            }
            current = try current.parent() orelse return null;
        }
    }

    // don't use parser.nodeHasAttributes(...) because that returns true/false
    // based on the type, e.g. a node never as attributes, an element always has
    // attributes. But, Element.hasAttributes is supposed to return true only
    // if the element has at least 1 attribute.
    pub fn _hasAttributes(self: *parser.Element) !bool {
        // an element _must_ have at least an empty attribute
        const node_map = try parser.nodeGetAttributes(parser.elementToNode(self)) orelse unreachable;
        return try parser.namedNodeMapGetLength(node_map) > 0;
    }

    pub fn _getAttribute(self: *parser.Element, qname: []const u8) !?[]const u8 {
        return try parser.elementGetAttribute(self, qname);
    }

    pub fn _getAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8) !?[]const u8 {
        return try parser.elementGetAttributeNS(self, ns, qname);
    }

    pub fn _setAttribute(self: *parser.Element, qname: []const u8, value: []const u8) !void {
        return try parser.elementSetAttribute(self, qname, value);
    }

    pub fn _setAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8, value: []const u8) !void {
        return try parser.elementSetAttributeNS(self, ns, qname, value);
    }

    pub fn _removeAttribute(self: *parser.Element, qname: []const u8) !void {
        return try parser.elementRemoveAttribute(self, qname);
    }

    pub fn _removeAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8) !void {
        return try parser.elementRemoveAttributeNS(self, ns, qname);
    }

    pub fn _hasAttribute(self: *parser.Element, qname: []const u8) !bool {
        return try parser.elementHasAttribute(self, qname);
    }

    pub fn _hasAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8) !bool {
        return try parser.elementHasAttributeNS(self, ns, qname);
    }

    // https://dom.spec.whatwg.org/#dom-element-toggleattribute
    pub fn _toggleAttribute(self: *parser.Element, qname: []u8, force: ?bool) !bool {
        _ = std.ascii.lowerString(qname, qname);
        const exists = try parser.elementHasAttribute(self, qname);

        // If attribute is null, then:
        if (!exists) {
            // If force is not given or is true, create an attribute whose
            // local name is qualifiedName, value is the empty string and node
            // document is this’s node document, then append this attribute to
            // this, and then return true.
            if (force == null or force.?) {
                try parser.elementSetAttribute(self, qname, "");
                return true;
            }
            if (try parser.validateName(qname) == false) {
                return parser.DOMError.InvalidCharacter;
            }

            // Return false.
            return false;
        }

        // Otherwise, if force is not given or is false, remove an attribute
        // given qualifiedName and this, and then return false.
        if (force == null or !force.?) {
            try parser.elementRemoveAttribute(self, qname);
            return false;
        }

        // Return true.
        return true;
    }

    pub fn _getAttributeNames(self: *parser.Element, page: *Page) ![]const []const u8 {
        const attributes = try parser.nodeGetAttributes(@ptrCast(self)) orelse return &.{};
        const ln = try parser.namedNodeMapGetLength(attributes);

        const names = try page.call_arena.alloc([]const u8, ln);
        var at: usize = 0;

        for (0..ln) |i| {
            const attribute = try parser.namedNodeMapItem(attributes, @intCast(i)) orelse break;
            names[at] = try parser.attributeGetName(attribute);
            at += 1;
        }

        return names[0..at];
    }

    pub fn _getAttributeNode(self: *parser.Element, name: []const u8) !?*parser.Attribute {
        return try parser.elementGetAttributeNode(self, name);
    }

    pub fn _getAttributeNodeNS(self: *parser.Element, ns: []const u8, name: []const u8) !?*parser.Attribute {
        return try parser.elementGetAttributeNodeNS(self, ns, name);
    }

    pub fn _setAttributeNode(self: *parser.Element, attr: *parser.Attribute) !?*parser.Attribute {
        return try parser.elementSetAttributeNode(self, attr);
    }

    pub fn _setAttributeNodeNS(self: *parser.Element, attr: *parser.Attribute) !?*parser.Attribute {
        return try parser.elementSetAttributeNodeNS(self, attr);
    }

    pub fn _removeAttributeNode(self: *parser.Element, attr: *parser.Attribute) !*parser.Attribute {
        return try parser.elementRemoveAttributeNode(self, attr);
    }

    pub fn _getElementsByTagName(
        self: *parser.Element,
        tag_name: []const u8,
        page: *Page,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(
            page.arena,
            parser.elementToNode(self),
            tag_name,
            .{ .include_root = false },
        );
    }

    pub fn _getElementsByClassName(
        self: *parser.Element,
        classNames: []const u8,
        page: *Page,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByClassName(
            page.arena,
            parser.elementToNode(self),
            classNames,
            .{ .include_root = false },
        );
    }

    // ParentNode
    // https://dom.spec.whatwg.org/#parentnode
    pub fn get_children(self: *parser.Element) !collection.HTMLCollection {
        return collection.HTMLCollectionChildren(parser.elementToNode(self), .{
            .include_root = false,
        });
    }

    pub fn get_firstElementChild(self: *parser.Element) !?Union {
        var children = try get_children(self);
        return try children._item(0);
    }

    pub fn get_lastElementChild(self: *parser.Element) !?Union {
        // TODO we could check the last child node first, if it's an element,
        // we can return it directly instead of looping twice over the
        // children.
        var children = try get_children(self);
        const ln = try children.get_length();
        if (ln == 0) return null;
        return try children._item(ln - 1);
    }

    pub fn get_childElementCount(self: *parser.Element) !u32 {
        var children = try get_children(self);
        return try children.get_length();
    }

    // NonDocumentTypeChildNode
    // https://dom.spec.whatwg.org/#interface-nondocumenttypechildnode
    pub fn get_previousElementSibling(self: *parser.Element) !?Union {
        const res = try parser.nodePreviousElementSibling(parser.elementToNode(self));
        if (res == null) return null;
        return try toInterface(res.?);
    }

    pub fn get_nextElementSibling(self: *parser.Element) !?Union {
        const res = try parser.nodeNextElementSibling(parser.elementToNode(self));
        if (res == null) return null;
        return try toInterface(res.?);
    }

    fn getElementById(self: *parser.Element, id: []const u8) !?*parser.Node {
        // walk over the node tree fo find the node by id.
        const root = parser.elementToNode(self);
        const walker = Walker{};
        var next: ?*parser.Node = null;
        while (true) {
            next = try walker.get_next(root, next) orelse return null;
            // ignore non-element nodes.
            if (try parser.nodeType(next.?) != .element) {
                continue;
            }
            const e = parser.nodeToElement(next.?);
            if (std.mem.eql(u8, id, try get_id(e))) return next;
        }
    }

    pub fn _querySelector(self: *parser.Element, selector: []const u8, page: *Page) !?Union {
        if (selector.len == 0) return null;

        const n = try css.querySelector(page.call_arena, parser.elementToNode(self), selector);

        if (n == null) return null;

        return try toInterface(parser.nodeToElement(n.?));
    }

    pub fn _querySelectorAll(self: *parser.Element, selector: []const u8, page: *Page) !NodeList {
        return css.querySelectorAll(page.arena, parser.elementToNode(self), selector);
    }

    pub fn _prepend(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        return Node.prepend(parser.elementToNode(self), nodes);
    }

    pub fn _append(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        return Node.append(parser.elementToNode(self), nodes);
    }

    pub fn _before(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        const ref_node = parser.elementToNode(self);
        return Node.before(ref_node, nodes);
    }

    pub fn _after(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        const ref_node = parser.elementToNode(self);
        return Node.after(ref_node, nodes);
    }

    pub fn _replaceChildren(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        return Node.replaceChildren(parser.elementToNode(self), nodes);
    }

    // A DOMRect object providing information about the size of an element and its position relative to the viewport.
    // Returns a 0 DOMRect object if the element is eventually detached from the main window
    pub fn _getBoundingClientRect(self: *parser.Element, page: *Page) !DOMRect {
        // Since we are lazy rendering we need to do this check. We could store the renderer in a viewport such that it could cache these, but it would require tracking changes.
        if (!try page.isNodeAttached(parser.elementToNode(self))) {
            return DOMRect{
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
                .bottom = 0,
                .right = 0,
                .top = 0,
                .left = 0,
            };
        }
        return page.renderer.getRect(self);
    }

    // Returns a collection of DOMRect objects that indicate the bounding rectangles for each CSS border box in a client.
    // We do not render so it only always return the element's bounding rect.
    // Returns an empty array if the element is eventually detached from the main window
    pub fn _getClientRects(self: *parser.Element, page: *Page) ![]DOMRect {
        if (!try page.isNodeAttached(parser.elementToNode(self))) {
            return &.{};
        }
        const heap_ptr = try page.call_arena.create(DOMRect);
        heap_ptr.* = try page.renderer.getRect(self);
        return heap_ptr[0..1];
    }

    pub fn get_clientWidth(_: *parser.Element, page: *Page) u32 {
        return page.renderer.width();
    }

    pub fn get_clientHeight(_: *parser.Element, page: *Page) u32 {
        return page.renderer.height();
    }

    pub fn _matches(self: *parser.Element, selectors: []const u8, page: *Page) !bool {
        const cssParse = @import("../css/css.zig").parse;
        const CssNodeWrap = @import("../css/libdom.zig").Node;
        const s = try cssParse(page.call_arena, selectors, .{});
        return s.match(CssNodeWrap{ .node = parser.elementToNode(self) });
    }

    pub fn _scrollIntoViewIfNeeded(_: *parser.Element, center_if_needed: ?bool) void {
        _ = center_if_needed;
    }

    const CheckVisibilityOpts = struct {
        contentVisibilityAuto: bool,
        opacityProperty: bool,
        visibilityProperty: bool,
    };

    pub fn _checkVisibility(self: *parser.Element, opts: ?CheckVisibilityOpts) bool {
        _ = self;
        _ = opts;
        return true;
    }

    const AttachShadowOpts = struct {
        mode: []const u8, // must be specified
    };
    pub fn _attachShadow(self: *parser.Element, opts: AttachShadowOpts, page: *Page) !*ShadowRoot {
        const mode = std.meta.stringToEnum(ShadowRoot.Mode, opts.mode) orelse return error.InvalidArgument;
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        if (state.shadow_root) |sr| {
            if (mode != sr.mode) {
                // this is the behavior per the spec
                return error.NotSupportedError;
            }

            try Node.removeChildren(@ptrCast(@alignCast(sr.proto)));
            return sr;
        }

        // Not sure what to do if there is no owner document
        const doc = try parser.nodeOwnerDocument(@ptrCast(self)) orelse return error.InvalidArgument;
        const fragment = try parser.documentCreateDocumentFragment(doc);
        const sr = try page.arena.create(ShadowRoot);
        sr.* = .{
            .host = self,
            .mode = mode,
            .proto = fragment,
        };
        state.shadow_root = sr;
        parser.documentFragmentSetHost(sr.proto, @ptrCast(@alignCast(self)));

        // Storing the ShadowRoot on the element makes sense, it's the ShadowRoot's
        // parent. When we render, we go top-down, so we'll have the element, get
        // its shadowroot, and go on. that's what the above code does.
        // But we sometimes need to go bottom-up, e.g when we have a slot element
        // and want to find the containing parent. Unforatunately , we don't have
        // that link, so we need to create it. In the DOM, the ShadowRoot is
        // represented by this DocumentFragment (it's the ShadowRoot's base prototype)
        // So we can also store the ShadowRoot in the DocumentFragment's state.
        const fragment_state = try page.getOrCreateNodeState(@ptrCast(@alignCast(fragment)));
        fragment_state.shadow_root = sr;

        return sr;
    }

    pub fn get_shadowRoot(self: *parser.Element, page: *Page) ?*ShadowRoot {
        const state = page.getNodeState(@ptrCast(@alignCast(self))) orelse return null;
        const sr = state.shadow_root orelse return null;
        if (sr.mode == .closed) {
            return null;
        }
        return sr;
    }

    pub fn _animate(self: *parser.Element, effect: JsObject, opts: JsObject) !Animation {
        _ = self;
        _ = opts;
        return Animation.constructor(effect, null);
    }

    pub fn _remove(self: *parser.Element) !void {
        // TODO: This hasn't been tested to make sure all references to this
        // node are properly updated. A lot of libdom is lazy and will look
        // for related elements JIT by walking the tree, but there could be
        // cases in libdom or the Zig WebAPI where this reference is kept
        const as_node: *parser.Node = @ptrCast(self);
        const parent = try parser.nodeParentNode(as_node) orelse return;
        _ = try Node._removeChild(parent, as_node);
    }
};

// Tests
// -----

const testing = @import("../../testing.zig");
test "Browser: DOM.Element" {
    try testing.htmlRunner("dom/element.html");
}
