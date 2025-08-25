// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const URL = @import("../../url.zig").URL;
const Page = @import("../page.zig").Page;

// https://developer.mozilla.org/en-US/docs/Web/API/Headers
const Headers = @This();

headers: std.StringHashMapUnmanaged([]const u8),

// They can either be:
//
// 1. An array of string pairs.
// 2. An object with string keys to string values.
// 3. Another Headers object.
const HeadersInit = union(enum) {
    strings: []const []const u8,
    // headers: Headers,
};

pub fn constructor(_init: ?[]const HeadersInit, page: *Page) !Headers {
    const arena = page.arena;
    var headers = std.StringHashMapUnmanaged([]const u8).empty;

    if (_init) |init| {
        for (init) |item| {
            switch (item) {
                .strings => |pair| {
                    // Can only have two string elements if in a pair.
                    if (pair.len != 2) {
                        return error.TypeError;
                    }

                    const raw_key = pair[0];
                    const value = pair[1];
                    const key = try std.ascii.allocLowerString(arena, raw_key);

                    try headers.put(arena, key, value);
                },
                // .headers => |_| {},
            }
        }
    }

    return .{
        .headers = headers,
    };
}

pub fn _get(self: *const Headers, header: []const u8, page: *Page) !?[]const u8 {
    const arena = page.arena;
    const key = try std.ascii.allocLowerString(arena, header);

    const value = (self.headers.getEntry(key) orelse return null).value_ptr.*;
    return try arena.dupe(u8, value);
}

const testing = @import("../../testing.zig");
test "fetch: headers" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let empty_headers = new Headers()", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "let headers = new Headers([['Set-Cookie', 'name=world']])", "undefined" },
        .{ "headers.get('set-cookie')", "name=world" },
    }, .{});
}
