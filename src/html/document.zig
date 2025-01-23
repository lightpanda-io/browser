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

const parser = @import("netsurf");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Node = @import("../dom/node.zig").Node;
const Document = @import("../dom/document.zig").Document;
const NodeList = @import("../dom/nodelist.zig").NodeList;
const HTMLElem = @import("elements.zig");
const Location = @import("location.zig").Location;

const collection = @import("../dom/html_collection.zig");
const Walker = @import("../dom/walker.zig").WalkerDepthFirst;

// WEB IDL https://html.spec.whatwg.org/#the-document-object
pub const HTMLDocument = struct {
    pub const Self = parser.DocumentHTML;
    pub const prototype = *Document;
    pub const mem_guarantied = true;

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

    // TODO: not implemented by libdom
    pub fn get_cookie(_: *parser.DocumentHTML) ![]const u8 {
        return error.NotImplemented;
    }

    // TODO: not implemented by libdom
    pub fn set_cookie(_: *parser.DocumentHTML, _: []const u8) ![]const u8 {
        return error.NotImplemented;
    }

    pub fn get_title(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetTitle(self);
    }

    pub fn set_title(self: *parser.DocumentHTML, v: []const u8) ![]const u8 {
        try parser.documentHTMLSetTitle(self, v);
        return v;
    }

    pub fn _getElementsByName(self: *parser.DocumentHTML, alloc: std.mem.Allocator, name: []const u8) !NodeList {
        var list = NodeList.init();
        errdefer list.deinit(alloc);

        if (name.len == 0) return list;

        const root = parser.documentHTMLToNode(self);
        var c = try collection.HTMLCollectionByName(alloc, root, name, false);

        const ln = try c.get_length();
        var i: u32 = 0;
        while (i < ln) {
            const n = try c.item(i) orelse break;
            try list.append(alloc, n);
            i += 1;
        }

        return list;
    }

    pub fn get_images(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, parser.documentHTMLToNode(self), "img", false);
    }

    pub fn get_embeds(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, parser.documentHTMLToNode(self), "embed", false);
    }

    pub fn get_plugins(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return get_embeds(self, alloc);
    }

    pub fn get_forms(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, parser.documentHTMLToNode(self), "form", false);
    }

    pub fn get_scripts(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, parser.documentHTMLToNode(self), "script", false);
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

    pub fn deinit(_: *parser.DocumentHTML, _: std.mem.Allocator) void {}
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var constructor = [_]Case{
        .{ .src = "document.__proto__.constructor.name", .ex = "HTMLDocument" },
        .{ .src = "document.__proto__.__proto__.constructor.name", .ex = "Document" },
        .{ .src = "document.body.localName == 'body'", .ex = "true" },
    };
    try checkCases(js_env, &constructor);

    var getters = [_]Case{
        .{ .src = "document.domain", .ex = "" },
        .{ .src = "document.referrer", .ex = "" },
        .{ .src = "document.title", .ex = "" },
        .{ .src = "document.body.localName", .ex = "body" },
        .{ .src = "document.head.localName", .ex = "head" },
        .{ .src = "document.images.length", .ex = "0" },
        .{ .src = "document.embeds.length", .ex = "0" },
        .{ .src = "document.plugins.length", .ex = "0" },
        .{ .src = "document.scripts.length", .ex = "0" },
        .{ .src = "document.forms.length", .ex = "0" },
        .{ .src = "document.links.length", .ex = "1" },
        .{ .src = "document.applets.length", .ex = "0" },
        .{ .src = "document.anchors.length", .ex = "0" },
        .{ .src = "document.all.length", .ex = "8" },
        .{ .src = "document.currentScript", .ex = "null" },
    };
    try checkCases(js_env, &getters);

    var titles = [_]Case{
        .{ .src = "document.title = 'foo'", .ex = "foo" },
        .{ .src = "document.title", .ex = "foo" },
        .{ .src = "document.title = ''", .ex = "" },
    };
    try checkCases(js_env, &titles);

    var getElementsByName = [_]Case{
        .{ .src = "document.getElementById('link').setAttribute('name', 'foo')", .ex = "undefined" },
        .{ .src = "let list = document.getElementsByName('foo')", .ex = "undefined" },
        .{ .src = "list.length", .ex = "1" },
    };
    try checkCases(js_env, &getElementsByName);
}
