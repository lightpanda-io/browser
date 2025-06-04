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

    pub fn get_domain(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetDomain(self);
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
        try page.cookie_jar.forRequest(&page.url.uri, buf.writer(page.arena), .{ .navigation = true });
        return buf.items;
    }

    pub fn set_cookie(_: *parser.DocumentHTML, cookie_str: []const u8, page: *Page) ![]const u8 {
        // we use the cookie jar's allocator to parse the cookie because it
        // outlives the page's arena.
        const c = try Cookie.parse(page.cookie_jar.allocator, &page.url.uri, cookie_str);
        errdefer c.deinit();
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
        const arena = page.arena;
        var list: NodeList = .{};

        if (name.len == 0) return list;

        const root = parser.documentHTMLToNode(self);
        var c = try collection.HTMLCollectionByName(arena, root, name, false);

        const ln = try c.get_length();
        var i: u32 = 0;
        while (i < ln) {
            const n = try c.item(i) orelse break;
            try list.append(arena, n);
            i += 1;
        }

        return list;
    }

    pub fn get_images(self: *parser.DocumentHTML, page: *Page) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(page.arena, parser.documentHTMLToNode(self), "img", false);
    }

    pub fn get_embeds(self: *parser.DocumentHTML, page: *Page) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(page.arena, parser.documentHTMLToNode(self), "embed", false);
    }

    pub fn get_plugins(self: *parser.DocumentHTML, page: *Page) !collection.HTMLCollection {
        return get_embeds(self, page);
    }

    pub fn get_forms(self: *parser.DocumentHTML, page: *Page) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(page.arena, parser.documentHTMLToNode(self), "form", false);
    }

    pub fn get_scripts(self: *parser.DocumentHTML, page: *Page) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(page.arena, parser.documentHTMLToNode(self), "script", false);
    }

    pub fn get_applets(_: *parser.DocumentHTML) !collection.HTMLCollection {
        return try collection.HTMLCollectionEmpty();
    }

    pub fn get_links(self: *parser.DocumentHTML) !collection.HTMLCollection {
        return try collection.HTMLCollectionByLinks(parser.documentHTMLToNode(self), false);
    }

    pub fn get_anchors(self: *parser.DocumentHTML) !collection.HTMLCollection {
        return try collection.HTMLCollectionByAnchors(parser.documentHTMLToNode(self), false);
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
        const state = try page.getOrCreateNodeState(@ptrCast(self));
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
    pub fn _elementFromPoint(_: *parser.DocumentHTML, x: f32, y: f32, page: *Page) !?ElementUnion {
        const ix: i32 = @intFromFloat(@floor(x));
        const iy: i32 = @intFromFloat(@floor(y));
        const element = page.renderer.getElementAtPosition(ix, iy) orelse return null;
        // TODO if pointer-events set to none the underlying element should be returned (parser.documentGetDocumentElement(self.document);?)
        return try Element.toInterface(element);
    }

    // Returns an array of all elements at the specified coordinates (relative to the viewport). The elements are ordered from the topmost to the bottommost box of the viewport.
    pub fn _elementsFromPoint(_: *parser.DocumentHTML, x: f32, y: f32, page: *Page) ![]ElementUnion {
        const ix: i32 = @intFromFloat(@floor(x));
        const iy: i32 = @intFromFloat(@floor(y));
        const element = page.renderer.getElementAtPosition(ix, iy) orelse return &.{};
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
        const state = try page.getOrCreateNodeState(@ptrCast(self));
        state.ready_state = .interactive;

        const evt = try parser.eventCreate();
        defer parser.eventDestroy(evt);

        log.debug(.script_event, "dispatch event", .{
            .type = "DOMContentLoaded",
            .source = "document",
        });
        try parser.eventInit(evt, "DOMContentLoaded", .{ .bubbles = true, .cancelable = true });
        _ = try parser.eventTargetDispatchEvent(parser.toEventTarget(parser.DocumentHTML, self), evt);
    }

    pub fn documentIsComplete(self: *parser.DocumentHTML, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@ptrCast(self));
        state.ready_state = .complete;
    }
};

// Tests
// -----

const testing = @import("../../testing.zig");

test "Browser.HTML.Document" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "document.__proto__.constructor.name", "HTMLDocument" },
        .{ "document.__proto__.__proto__.constructor.name", "Document" },
        .{ "document.body.localName == 'body'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.domain", "" },
        .{ "document.referrer", "" },
        .{ "document.title", "" },
        .{ "document.body.localName", "body" },
        .{ "document.head.localName", "head" },
        .{ "document.images.length", "0" },
        .{ "document.embeds.length", "0" },
        .{ "document.plugins.length", "0" },
        .{ "document.scripts.length", "0" },
        .{ "document.forms.length", "0" },
        .{ "document.links.length", "1" },
        .{ "document.applets.length", "0" },
        .{ "document.anchors.length", "0" },
        .{ "document.all.length", "8" },
        .{ "document.currentScript", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.title = 'foo'", "foo" },
        .{ "document.title", "foo" },
        .{ "document.title = ''", "" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.getElementById('link').setAttribute('name', 'foo')", "undefined" },
        .{ "let list = document.getElementsByName('foo')", "undefined" },
        .{ "list.length", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.cookie", "" },
        .{ "document.cookie = 'name=Oeschger; SameSite=None; Secure'", "name=Oeschger; SameSite=None; Secure" },
        .{ "document.cookie = 'favorite_food=tripe; SameSite=None; Secure'", "favorite_food=tripe; SameSite=None; Secure" },
        .{ "document.cookie", "name=Oeschger; favorite_food=tripe" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.elementFromPoint(0.5, 0.5)", "null" }, //  Return null since we only return element s when they have previously been localized
        .{ "document.elementsFromPoint(0.5, 0.5)", "" },
        .{
            \\ let div1 = document.createElement('div');
            \\ document.body.appendChild(div1);
            \\ div1.getClientRects();
            ,
            null,
        },
        .{ "document.elementFromPoint(0.5, 0.5)", "[object HTMLDivElement]" },
        .{ "let elems = document.elementsFromPoint(0.5, 0.5)", null },
        .{ "elems.length", "3" },
        .{ "elems[0]", "[object HTMLDivElement]" },
        .{ "elems[1]", "[object HTMLBodyElement]" },
        .{ "elems[2]", "[object HTMLHtmlElement]" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ let a = document.createElement('a');
            \\ a.href = "https://lightpanda.io";
            \\ document.body.appendChild(a);
            \\ a.getClientRects();
            , // Note this will be placed after the div of previous test
            null,
        },
        .{ "let a_again = document.elementFromPoint(1.5, 0.5)", null },
        .{ "a_again", "[object HTMLAnchorElement]" },
        .{ "a_again.href", "https://lightpanda.io" },
        .{ "let a_agains = document.elementsFromPoint(1.5, 0.5)", null },
        .{ "a_agains[0].href", "https://lightpanda.io" },
    }, .{});

    try runner.testCases(&.{
        .{ "!document.all", "true" },
        .{ "!!document.all", "false" },
        .{ "document.all(5)", "[object HTMLParagraphElement]" },
        .{ "document.all('content')", "[object HTMLDivElement]" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.defaultView.document == document", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.readyState", "loading" },
    }, .{});

    try HTMLDocument.documentIsLoaded(runner.page.window.document, runner.page);
    try runner.testCases(&.{
        .{ "document.readyState", "interactive" },
    }, .{});

    try HTMLDocument.documentIsComplete(runner.page.window.document, runner.page);
    try runner.testCases(&.{
        .{ "document.readyState", "complete" },
    }, .{});
}
