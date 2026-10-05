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
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

const Details = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Details) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Details) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Details) *Node {
    return self.asElement().asNode();
}

pub fn setOpen(self: *Details, open: bool, frame: *Frame) !void {
    if (open) {
        try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("open"), frame);
    }
}

pub fn getOpen(self: *const Details) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("open")) != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Details);

    pub const Meta = struct {
        pub const name = "HTMLDetailsElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Details);

    pub const open = reflect.boolean("open");
    pub const name = reflect.string("name");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Details" {
    try testing.htmlRunner("element/html/details.html", .{});
}

test "WebApi: HTML.Summary click toggles parent details" {
    try testing.htmlRunner("element/html/summary_click.html", .{});
}
