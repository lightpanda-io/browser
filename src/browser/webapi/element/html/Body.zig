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

const log = @import("../../../../log.zig");

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Body = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Body) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Body) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Body);

    pub const Meta = struct {
        pub const name = "HTMLBodyElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

pub const Build = struct {
    pub fn complete(node: *Node, page: *Page) !void {
        const el = node.as(Element);
        const on_load = el.getAttributeSafe("onload") orelse return;
        if (page.js.stringToFunction(on_load)) |func| {
            page.window._on_load = try func.persist();
        } else |err| {
            log.err(.js, "body.onload", .{ .err = err, .str = on_load });
        }
    }
};
