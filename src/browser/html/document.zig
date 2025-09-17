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

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

const Window = @import("window.zig").Window;
const Element = @import("../dom/element.zig").Element;
const ElementUnion = @import("../dom/element.zig").Union;
const Document = @import("../dom/document.zig").Document;
const NodeList = @import("../dom/nodelist.zig").NodeList;
const Location = @import("location.zig").Location;

const collection = @import("../dom/html_collection.zig");
const Walker = @import("../dom/walker.zig").WalkerDepthFirst;
const Cookie = @import("../storage/cookie.zig").Cookie;

// WEB IDL https://html.spec.whatwg.org/#the-document-object
pub const HTMLDocument = struct {
    pub const Self = parser.DocumentHTML;
    pub const prototype = *Document;
    pub const subtype = .node;

    // JS funcs
    // --------

    pub fn get_domain(self: *parser.DocumentHTML, page: *Page) ![]const u8 {
        // libdom's document_html get_domain always returns null, this is
        // the way MDN recommends getting the domain anyways, since document.domain
        // is deprecated.
        const location = try parser.documentHTMLGetLocation(Location, self) orelse return "";
        return location.get_host(page);
    }

    pub fn set_domain(_: *parser.DocumentHTML, _: []const u8) ![]const u8 {
        return error.NotImplemented;
    }

    pub fn get_referrer(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetReferrer(self);
    }

    pub fn set_referrer(_: *parser.DocumentHTML, _: []const u8) ![]const u8 {
        return error.NotImplemented;
    }

    pub fn get_body(self: *parser.DocumentHTML) !?*parser.Body {
        return try parser.documentHTMLBody(self);
    }

    pub fn set_body(self: *parser.DocumentHTML, elt: ?*parser.ElementHTML) !?*parser.Body {
        try parser.documentHTMLSetBody(self, elt);
        return try get_body(self);
    }

    pub fn get_head(self: *parser.DocumentHTML) !?*parser.Head {
        const root = parser.documentHTMLToNode(self);
        const walker = Walker{};
        var next: ?*parser.Node = null;
        while (true) {
            next = try walker.get_next(root, next) orelse return null;
            if (std.ascii.eqlIgnoreCase("head", try parser.nodeName(next.?))) {
                return @as(*parser.Head, @ptrCast(next.?));
            }
        }
    }

    pub fn get_cookie(_: *parser.DocumentHTML, page: *Page) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        try page.cookie_jar.forRequest(&page.url.uri, buf.writer(page.arena), .{
            .is_http = false,
            .is_navigation = true,
        });
        return buf.items;
    }

    pub fn set_cookie(_: *parser.DocumentHTML, cookie_str: []const u8, page: *Page) ![]const u8 {
        // we use the cookie jar's allocator to parse the cookie because it
        // outlives the page's arena.
        const c = try Cookie.parse(page.cookie_jar.allocator, &page.url.uri, cookie_str);
        errdefer c.deinit();
        if (c.http_only) {
            c.deinit();
            return ""; // HttpOnly cookies cannot be set from JS
        }
        try page.cookie_jar.add(c, std.time.timestamp());
        return cookie_str;
    }

    pub fn get_title(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetTitle(self);
    }

    pub fn set_title(self: *parser.DocumentHTML, v: []const u8) ![]const u8 {
        try parser.documentHTMLSetTitle(self, v);
        return v;
    }

    pub fn _getElementsByName(self: *parser.DocumentHTML, name: []const u8, page: *Page) !NodeList {
        var list: NodeList = .{};

        if (name.len == 0) {
            return list;
        }

        const root = parser.documentHTMLToNode(self);
        var c = try collection.HTMLCollectionByName(root, name, .{
            .include_root = false,
        });

        const ln = try c.get_length();
        try list.ensureTotalCapacity(page.arena, ln);

        var i: u32 = 0;
        while (i < ln) : (i += 1) {
            const n = try c.item(i) orelse break;
            list.appendAssumeCapacity(n);
        }

        return list;
    }

    pub fn get_images(self: *parser.DocumentHTML) collection.HTMLCollection {
        return collection.HTMLCollectionByTagName(parser.documentHTMLToNode(self), "img", .{
            .include_root = false,
        });
    }

    pub fn get_embeds(self: *parser.DocumentHTML) collection.HTMLCollection {
        return collection.HTMLCollectionByTagName(parser.documentHTMLToNode(self), "embed", .{
            .include_root = false,
        });
    }

    pub fn get_plugins(self: *parser.DocumentHTML) collection.HTMLCollection {
        return get_embeds(self);
    }

    pub fn get_forms(self: *parser.DocumentHTML) collection.HTMLCollection {
        return collection.HTMLCollectionByTagName(parser.documentHTMLToNode(self), "form", .{
            .include_root = false,
        });
    }

    pub fn get_scripts(self: *parser.DocumentHTML) collection.HTMLCollection {
        return collection.HTMLCollectionByTagName(parser.documentHTMLToNode(self), "script", .{
            .include_root = false,
        });
    }

    pub fn get_applets(_: *parser.DocumentHTML) collection.HTMLCollection {
        return collection.HTMLCollectionEmpty();
    }

    pub fn get_links(self: *parser.DocumentHTML) collection.HTMLCollection {
        return collection.HTMLCollectionByLinks(parser.documentHTMLToNode(self), .{
            .include_root = false,
        });
    }

    pub fn get_anchors(self: *parser.DocumentHTML) collection.HTMLCollection {
        return collection.HTMLCollectionByAnchors(parser.documentHTMLToNode(self), .{
            .include_root = false,
        });
    }

    pub fn get_all(self: *parser.DocumentHTML) collection.HTMLAllCollection {
        return collection.HTMLAllCollection.init(parser.documentHTMLToNode(self));
    }

    pub fn get_currentScript(self: *parser.DocumentHTML) !?*parser.Script {
        return try parser.documentHTMLGetCurrentScript(self);
    }

    pub fn get_location(self: *parser.DocumentHTML) !?*Location {
        return try parser.documentHTMLGetLocation(Location, self);
    }

    pub fn set_location(_: *const parser.DocumentHTML, url: []const u8, page: *Page) !void {
        return page.navigateFromWebAPI(url, .{ .reason = .script });
    }

    pub fn get_designMode(_: *parser.DocumentHTML) []const u8 {
        return "off";
    }

    pub fn set_designMode(_: *parser.DocumentHTML, _: []const u8) []const u8 {
        return "off";
    }

    pub fn get_defaultView(_: *parser.DocumentHTML, page: *Page) *Window {
        return &page.window;
    }

    pub fn get_readyState(self: *parser.DocumentHTML, page: *Page) ![]const u8 {
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        return @tagName(state.ready_state);
    }

    // noop legacy functions
    // https://html.spec.whatwg.org/#Document-partial
    pub fn _clear(_: *parser.DocumentHTML) void {}
    pub fn _captureEvents(_: *parser.DocumentHTML) void {}
    pub fn _releaseEvents(_: *parser.DocumentHTML) void {}

    pub fn get_fgColor(_: *parser.DocumentHTML) []const u8 {
        return "";
    }
    pub fn set_fgColor(_: *parser.DocumentHTML, _: []const u8) []const u8 {
        return "";
    }
    pub fn get_linkColor(_: *parser.DocumentHTML) []const u8 {
        return "";
    }
    pub fn set_linkColor(_: *parser.DocumentHTML, _: []const u8) []const u8 {
        return "";
    }
    pub fn get_vlinkColor(_: *parser.DocumentHTML) []const u8 {
        return "";
    }
    pub fn set_vlinkColor(_: *parser.DocumentHTML, _: []const u8) []const u8 {
        return "";
    }
    pub fn get_alinkColor(_: *parser.DocumentHTML) []const u8 {
        return "";
    }
    pub fn set_alinkColor(_: *parser.DocumentHTML, _: []const u8) []const u8 {
        return "";
    }
    pub fn get_bgColor(_: *parser.DocumentHTML) []const u8 {
        return "";
    }
    pub fn set_bgColor(_: *parser.DocumentHTML, _: []const u8) []const u8 {
        return "";
    }

    // Returns the topmost Element at the specified coordinates (relative to the viewport).
    // Since LightPanda requires the client to know what they are clicking on we do not return the underlying element at this moment
    // This can currenty only happen if the first pixel is clicked without having rendered any element. This will change when css properties are supported.
    // This returns an ElementUnion instead of a *Parser.Element in case the element somehow hasn't passed through the js runtime yet.
    // While x and y should be f32, here we take i32 since that's what our
    // "renderer" uses. By specifying i32 here, rather than f32 and doing the
    // conversion ourself, we rely on v8's type conversion which is both more
    // flexible (e.g. handles NaN) and will be more consistent with a browser.
    pub fn _elementFromPoint(_: *parser.DocumentHTML, x: i32, y: i32, page: *Page) !?ElementUnion {
        const element = page.renderer.getElementAtPosition(x, y) orelse return null;
        // TODO if pointer-events set to none the underlying element should be returned (parser.documentGetDocumentElement(self.document);?)
        return try Element.toInterface(element);
    }

    // Returns an array of all elements at the specified coordinates (relative to the viewport). The elements are ordered from the topmost to the bottommost box of the viewport.
    // While x and y should be f32, here we take i32 since that's what our
    // "renderer" uses. By specifying i32 here, rather than f32 and doing the
    // conversion ourself, we rely on v8's type conversion which is both more
    // flexible (e.g. handles NaN) and will be more consistent with a browser.
    pub fn _elementsFromPoint(_: *parser.DocumentHTML, x: i32, y: i32, page: *Page) ![]ElementUnion {
        const element = page.renderer.getElementAtPosition(x, y) orelse return &.{};
        // TODO if pointer-events set to none the underlying element should be returned (parser.documentGetDocumentElement(self.document);?)

        var list: std.ArrayListUnmanaged(ElementUnion) = .empty;
        try list.ensureTotalCapacity(page.call_arena, 3);
        list.appendAssumeCapacity(try Element.toInterface(element));

        // Since we are using a flat renderer there is no hierarchy of elements. What we do know is that the element is part of the main document.
        // Thus we can add the HtmlHtmlElement and it's child HTMLBodyElement to the returned list.
        // TBD Should we instead return every parent that is an element? Note that a child does not physically need to be overlapping the parent.
        // Should we do a render pass on demand?
        const doc_elem = try parser.documentGetDocumentElement(parser.documentHTMLToDocument(page.window.document)) orelse {
            return list.items;
        };
        if (try parser.documentHTMLBody(page.window.document)) |body| {
            list.appendAssumeCapacity(try Element.toInterface(parser.bodyToElement(body)));
        }
        list.appendAssumeCapacity(try Element.toInterface(doc_elem));
        return list.items;
    }

    pub fn documentIsLoaded(self: *parser.DocumentHTML, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        state.ready_state = .interactive;

        log.debug(.script_event, "dispatch event", .{
            .type = "DOMContentLoaded",
            .source = "document",
        });

        const evt = try parser.eventCreate();
        defer parser.eventDestroy(evt);
        try parser.eventInit(evt, "DOMContentLoaded", .{ .bubbles = true, .cancelable = true });
        _ = try parser.eventTargetDispatchEvent(parser.toEventTarget(parser.DocumentHTML, self), evt);

        try page.window.dispatchForDocumentTarget(evt);
    }

    pub fn documentIsComplete(self: *parser.DocumentHTML, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        state.ready_state = .complete;
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.Document" {
    try testing.htmlRunner("html/document.html");
}
