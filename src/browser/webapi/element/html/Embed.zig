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

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Embed = @This();

pub const Proto = HtmlElement;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Embed) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Embed) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Embed) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Embed, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Embed, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Embed);

    pub const Meta = struct {
        pub const name = "HTMLEmbedElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Embed);
    pub const @"align" = reflect.string("align");
    pub const name = reflect.string("name");

    pub const height = reflect.string("height");
    pub const src = bridge.accessor(Embed.getSrc, Embed.setSrc, .{ .ce_reactions = true });
    pub const @"type" = reflect.string("type");
    pub const width = reflect.string("width");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Embed" {
    try testing.htmlRunner("element/html/embed.html", .{});
}
