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
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

const Marquee = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Marquee) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Marquee) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Marquee);

    pub const Meta = struct {
        pub const name = "HTMLMarqueeElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Marquee);

    pub const behavior = reflect.enumerated("behavior", &.{ "scroll", "slide", "alternate" }, .{ .missing = "scroll" });
    pub const bgColor = reflect.string("bgcolor");
    pub const direction = reflect.enumerated("direction", &.{ "up", "right", "down", "left" }, .{ .missing = "left" });
    pub const height = reflect.string("height");
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const scrollAmount = reflect.unsignedLong("scrollamount", .{ .default = 6 });
    pub const scrollDelay = reflect.unsignedLong("scrolldelay", .{ .default = 85 });
    pub const trueSpeed = reflect.boolean("truespeed");
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const width = reflect.string("width");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Marquee" {
    try testing.htmlRunner("element/html/marquee.html", .{});
}
