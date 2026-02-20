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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const CData = @import("../CData.zig");

const Text = @This();

_proto: *CData,

pub fn init(str: ?js.NullableString, page: *Page) !*Text {
    const node = try page.createTextNode(if (str) |s| s.value else "");
    return node.as(Text);
}

pub fn getWholeText(self: *Text) []const u8 {
    return self._proto._data;
}

pub fn splitText(self: *Text, offset: usize, page: *Page) !*Text {
    const data = self._proto._data;

    const byte_offset = CData.utf16OffsetToUtf8(data, offset) catch return error.IndexSizeError;

    const new_data = data[byte_offset..];
    const new_node = try page.createTextNode(new_data);
    const new_text = new_node.as(Text);

    const old_data = data[0..byte_offset];
    try self._proto.setData(old_data, page);

    // If this node has a parent, insert the new node right after this one
    const node = self._proto.asNode();
    if (node.parentNode()) |parent| {
        const next_sibling = node.nextSibling();
        _ = try parent.insertBefore(new_node, next_sibling, page);
    }

    return new_text;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Text);

    pub const Meta = struct {
        pub const name = "Text";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const constructor = bridge.constructor(Text.init, .{});
    pub const wholeText = bridge.accessor(Text.getWholeText, null, .{});
    pub const splitText = bridge.function(Text.splitText, .{ .dom_exception = true });
};
