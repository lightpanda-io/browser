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

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const URL = @import("../../URL.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Link = @This();
_proto: *HtmlElement,

pub fn asElement(self: *Link) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Link) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Link, page: *Page) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeSafe(comptime .literal("href")) orelse return "";
    if (href.len == 0) {
        return "";
    }

    // Always resolve the href against the page URL
    return URL.resolve(page.call_arena, page.base(), href, .{});
}

pub fn setHref(self: *Link, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("href", value, page);
}

pub fn getRel(self: *Link) []const u8 {
    return self.asElement().getAttributeSafe(comptime .literal("rel")) orelse return "";
}

pub fn setRel(self: *Link, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("rel", value, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Link);

    pub const Meta = struct {
        pub const name = "HTMLLinkElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const rel = bridge.accessor(Link.getRel, Link.setRel, .{});
    pub const href = bridge.accessor(Link.getHref, Link.setHref, .{});
    pub const relList = bridge.accessor(_getRelList, null, .{ .null_as_undefined = true });

    fn _getRelList(self: *Link, page: *Page) !?*@import("../../collections.zig").DOMTokenList {
        const element = self.asElement();
        // relList is only valid for HTML <link> elements, not SVG or MathML
        if (element._namespace != .html) {
            return null;
        }
        return element.getRelList(page);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Link" {
    try testing.htmlRunner("element/html/link.html", .{});
}
