// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const URL = @import("../../../URL.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

const String = lp.String;
const Base = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Base) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Base) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Base, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeInterned("href") orelse return "";
    if (href.len == 0) {
        return "";
    }
    const doc = element.asConstNode().ownerDocument(frame).?;
    return URL.resolve(frame.local_arena, doc.getURL(frame), href, .{});
}

pub fn setHref(self: *Base, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);

    if (element.asNode().isConnected() == false) return;
    try self.baseAddedCallback(frame);
}

fn baseAddedCallback(self: *Base, frame: *Frame) !void {
    // Per HTML spec, the document's base URL is the href of the FIRST <base>
    // element in tree order that has an href attribute — not necessarily this
    // one. Re-derive from scratch so that setting href on a non-authoritative
    // <base>, or clearing href on the authoritative one, both work correctly.
    const owner = self.asNode().ownerFrame(frame) orelse return;
    const first = (try owner.document.querySelector(comptime .wrap("base[href]"), owner)) orelse {
        owner.base_url = null;
        return;
    };
    const href = first.getAttributeInterned("href") orelse {
        owner.base_url = null;
        return;
    };
    if (href.len == 0) {
        owner.base_url = null;
        return;
    }
    owner.base_url = try URL.resolve(owner.arena, owner.url, href, .{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Base);

    pub const Meta = struct {
        pub const name = "HTMLBaseElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Base);

    pub const href = bridge.accessor(Base.getHref, Base.setHref, .{ .ce_reactions = true });
    pub const target = reflect.string("target");
};

pub const Build = struct {
    pub const parser_created_on_insert = true;

    pub fn created(node: *Node, frame: *Frame) !void {
        if (node.isConnected() == false) return;

        const self = node.as(Base);
        try self.baseAddedCallback(frame);
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("href"))) {
            return;
        }
        if (element.asNode().isConnected() == false) return;

        try element.as(Base).baseAddedCallback(frame);
    }

    // TODO handle attribute remove?
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Base" {
    try testing.htmlRunner("element/html/base.html", .{});
}
