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

const Page = @import("../../Page.zig");
const Allocator = std.mem.Allocator;

const Response = @This();

_status: u16,
_data: []const u8,
_arena: Allocator,

pub fn initFromFetch(arena: Allocator, data: []const u8, page: *Page) !*Response {
    return page._factory.create(Response{
        ._status = 200,
        ._data = data,
        ._arena = arena,
    });
}

pub fn getStatus(self: *const Response) u16 {
    return self._status;
}

pub fn isOK(self: *const Response) bool {
    return self._status >= 200 and self._status <= 299;
}

pub fn getJson(self: *Response, page: *Page) !js.Promise {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        page.call_arena,
        self._data,
        .{},
    ) catch |err| {
        return page.js.rejectPromise(.{@errorName(err)});
    };
    return page.js.resolvePromise(value);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Response);

    pub const Meta = struct {
        pub const name = "Response";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const ok = bridge.accessor(Response.isOK, null, .{});
    pub const status = bridge.accessor(Response.getStatus, null, .{});
    pub const json = bridge.function(Response.getJson, .{});
};
