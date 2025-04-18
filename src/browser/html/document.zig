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
const SessionState = @import("../env.zig").SessionState;

const Node = @import("../dom/node.zig").Node;
const Document = @import("../dom/document.zig").Document;
const NodeList = @import("../dom/nodelist.zig").NodeList;
const HTMLElem = @import("elements.zig");
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

    pub fn get_cookie(_: *parser.DocumentHTML, state: *SessionState) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        try state.cookie_jar.forRequest(&state.url.uri, buf.writer(state.arena), .{ .navigation = true });
        return buf.items;
    }

    pub fn set_cookie(_: *parser.DocumentHTML, cookie_str: []const u8, state: *SessionState) ![]const u8 {
        // we use the cookie jar's allocator to parse the cookie because it
        // outlives the page's arena.
        const c = try Cookie.parse(state.cookie_jar.allocator, &state.url.uri, cookie_str);
        errdefer c.deinit();
        try state.cookie_jar.add(c, std.time.timestamp());
        return cookie_str;
    }

    pub fn get_title(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetTitle(self);
    }

    pub fn set_title(self: *parser.DocumentHTML, v: []const u8) ![]const u8 {
        try parser.documentHTMLSetTitle(self, v);
        return v;
    }

    pub fn _getElementsByName(self: *parser.DocumentHTML, name: []const u8, state: *SessionState) !NodeList {
        const arena = state.arena;
        var list = NodeList.init();
        errdefer list.deinit(arena);

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

    pub fn get_images(self: *parser.DocumentHTML, state: *SessionState) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(state.arena, parser.documentHTMLToNode(self), "img", false);
    }

    pub fn get_embeds(self: *parser.DocumentHTML, state: *SessionState) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(state.arena, parser.documentHTMLToNode(self), "embed", false);
    }

    pub fn get_plugins(self: *parser.DocumentHTML, state: *SessionState) !collection.HTMLCollection {
        return get_embeds(self, state);
    }

    pub fn get_forms(self: *parser.DocumentHTML, state: *SessionState) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(state.arena, parser.documentHTMLToNode(self), "form", false);
    }

    pub fn get_scripts(self: *parser.DocumentHTML, state: *SessionState) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(state.arena, parser.documentHTMLToNode(self), "script", false);
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

    pub fn get_all(self: *parser.DocumentHTML) !collection.HTMLCollection {
        return try collection.HTMLCollectionAll(parser.documentHTMLToNode(self), true);
    }

    pub fn get_currentScript(self: *parser.DocumentHTML) !?*parser.Script {
        return try parser.documentHTMLGetCurrentScript(self);
    }

    pub fn get_location(self: *parser.DocumentHTML) !?*Location {
        return try parser.documentHTMLGetLocation(Location, self);
    }

    pub fn get_designMode(_: *parser.DocumentHTML) []const u8 {
        return "off";
    }

    pub fn set_designMode(_: *parser.DocumentHTML, _: []const u8) []const u8 {
        return "off";
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
}
