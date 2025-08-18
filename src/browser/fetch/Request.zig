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

// https://developer.mozilla.org/en-US/docs/Web/API/Request/Request
const Request = @This();

url: []const u8,

const RequestInput = union(enum) {
    string: []const u8,
    request: Request,
};

pub fn constructor(input: RequestInput, page: *Page) !Request {
    const arena = page.arena;

    const url = blk: switch (input) {
        .string => |str| {
            break :blk try URL.stitch(arena, str, page.url.raw, .{});
        },
        .request => |req| {
            break :blk try arena.dupe(u8, req.url);
        },
    };

    return .{
        .url = url,
    };
}

pub fn get_url(self: *const Request, page: *Page) ![]const u8 {
    return try page.arena.dupe(u8, self.url);
}

const testing = @import("../../testing.zig");
test "fetch: request" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let request = new Request('flower.png')", "undefined" },
        .{ "request.url", "https://lightpanda.io/flower.png" },
    }, .{});

    try runner.testCases(&.{
        .{ "let request2 = new Request('https://google.com')", "undefined" },
        .{ "request2.url", "https://google.com" },
    }, .{});
}
