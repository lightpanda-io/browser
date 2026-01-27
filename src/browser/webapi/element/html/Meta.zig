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
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Meta = @This();
// Because we have a JsApi.Meta, "Meta" can be ambiguous in some scopes.
// Create a different alias we can use when in such ambiguous cases.
const MetaElement = Meta;

_proto: *HtmlElement,

pub fn asElement(self: *Meta) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Meta) *Node {
    return self.asElement().asNode();
}

pub fn getName(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("name")) orelse return "";
}

pub fn setName(self: *Meta, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), page);
}

pub fn getHttpEquiv(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("http-equiv")) orelse return "";
}

pub fn setHttpEquiv(self: *Meta, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("http-equiv"), .wrap(value), page);
}

pub fn getContent(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("content")) orelse return "";
}

pub fn setContent(self: *Meta, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("content"), .wrap(value), page);
}

pub fn getMedia(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("media")) orelse return "";
}

pub fn setMedia(self: *Meta, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MetaElement);

    pub const Meta = struct {
        pub const name = "HTMLMetaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(MetaElement.getName, MetaElement.setName, .{});
    pub const httpEquiv = bridge.accessor(MetaElement.getHttpEquiv, MetaElement.setHttpEquiv, .{});
    pub const content = bridge.accessor(MetaElement.getContent, MetaElement.setContent, .{});
    pub const media = bridge.accessor(MetaElement.getMedia, MetaElement.setMedia, .{});
};
