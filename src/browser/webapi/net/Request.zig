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

const js = @import("../../js/js.zig");

const URL = @import("../URL.zig");
const Page = @import("../../Page.zig");
const Allocator = std.mem.Allocator;

const Request = @This();

_url: [:0]const u8,
_arena: Allocator,

pub const Input = union(enum) {
    url: [:0]const u8,
    // request: *Request, TODO
};

pub fn init(input: Input, page: *Page) !*Request {
    const arena = page.arena;
    const url = try URL.resolve(arena, page.url, input.url, .{ .always_dupe = true });

    return page._factory.create(Request{
        ._url = url,
        ._arena = arena,
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Request);

    pub const Meta = struct {
        pub const name = "Request";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Request.init, .{});
};
