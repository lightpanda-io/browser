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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
pub const Text = @import("cdata/Text.zig");
pub const Comment = @import("cdata/Comment.zig");

const CData = @This();

_type: Type,
_proto: *Node,
_data: []const u8 = "",

pub const Type = union(enum) {
    text: Text,
    comment: Comment,
};

pub fn asNode(self: *CData) *Node {
    return self._proto;
}

pub fn is(self: *CData, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (f.type == T and @field(Type, f.name) == self._type) {
            return &@field(self._type, f.name);
        }
    }
    return null;
}

pub fn className(self: *const CData) []const u8 {
    return switch (self._type) {
        .text => "[object Text]",
        .comment => "[object Comment]",
    };
}

pub fn getData(self: *const CData) []const u8 {
    return self._data;
}

pub fn setData(self: *CData, value: ?[]const u8, page: *Page) !void {
    const old_value = self._data;

    if (value) |v| {
        self._data = try page.dupeString(v);
    } else {
        self._data = "";
    }

    page.characterDataChange(self.asNode(), old_value);
}

pub fn format(self: *const CData, writer: *std.io.Writer) !void {
    return switch (self._type) {
        .text => writer.print("<text>{s}</text>", .{self._data}),
        .comment => writer.print("<comment>{s}</comment>", .{self._data}),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CData);

    pub const Meta = struct {
        pub const name = "CData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const data = bridge.accessor(CData.getData, CData.setData, .{});
};
