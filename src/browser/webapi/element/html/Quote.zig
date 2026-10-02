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

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Quote = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Quote) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Quote) *Node {
    return self.asElement().asNode();
}

fn getCite(self: *Quote, frame: *Frame) ![]const u8 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("cite")) orelse return "";
    if (attr.len == 0) return "";
    return self.asNode().resolveURLReflect(attr, frame, .{});
}

fn setCite(self: *Quote, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("cite"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Quote);

    pub const Meta = struct {
        pub const name = "HTMLQuoteElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cite = bridge.accessor(Quote.getCite, Quote.setCite, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Quote" {
    try testing.htmlRunner("element/html/quote.html", .{});
}
