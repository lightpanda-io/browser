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

const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const LI = @This();
_proto: *HtmlElement,

pub fn asElement(self: *LI) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *LI) *Node {
    return self.asElement().asNode();
}

pub fn getValue(self: *LI) i32 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("value")) orelse return 0;
    return std.fmt.parseInt(i32, attr, 10) catch 0;
}

pub fn setValue(self: *LI, value: i32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(str), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(LI);

    pub const Meta = struct {
        pub const name = "HTMLLIElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(LI.getValue, LI.setValue, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.LI" {
    try testing.htmlRunner("element/html/li.html", .{});
}
