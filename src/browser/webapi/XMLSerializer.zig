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
const dump = @import("../dump.zig");

const XMLSerializer = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

pub fn init() XMLSerializer {
    return .{};
}

pub fn serializeToString(self: *const XMLSerializer, node: *Node, page: *Page) ![]const u8 {
    _ = self;
    var buf = std.Io.Writer.Allocating.init(page.call_arena);
    if (node.is(Node.Document)) |doc| {
        try dump.root(doc, .{ .shadow = .skip }, &buf.writer, page);
    } else {
        try dump.deep(node, .{ .shadow = .skip }, &buf.writer, page);
    }
    // Not sure about this trim. But `dump` is meant to display relatively
    // pretty HTML, so it does include newlines, which can result in a trailing
    // newline. XMLSerializer is a bit more strict.
    return std.mem.trim(u8, buf.written(), &std.ascii.whitespace);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLSerializer);

    pub const Meta = struct {
        pub const name = "XMLSerializer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(XMLSerializer.init, .{});
    pub const serializeToString = bridge.function(XMLSerializer.serializeToString, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: XMLSerializer" {
    try testing.htmlRunner("xmlserializer.html", .{});
}
