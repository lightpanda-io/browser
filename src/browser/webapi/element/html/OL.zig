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
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const OL = @This();

pub const Proto = HtmlElement;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *OL) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *OL) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *OL) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("type")) orelse "1";
}

pub fn setType(self: *OL, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OL);

    pub const Meta = struct {
        pub const name = "HTMLOListElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(OL);
    pub const compact = reflect.boolean("compact");

    pub const start = reflect.long("start", 1);
    pub const reversed = reflect.boolean("reversed");
    pub const @"type" = bridge.accessor(OL.getType, OL.setType, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.OL" {
    try testing.htmlRunner("element/html/ol.html", .{});
}
