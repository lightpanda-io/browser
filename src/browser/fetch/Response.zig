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
const Env = @import("../env.zig").Env;

const v8 = @import("v8");

const Http = @import("../../http/Http.zig");
const HttpClient = @import("../../http/Client.zig");
const Mime = @import("../mime.zig").Mime;

// https://developer.mozilla.org/en-US/docs/Web/API/Response
const Response = @This();

status: u16 = 0,
headers: []const []const u8,
mime: ?Mime = null,
body: []const u8,

const ResponseInput = union(enum) {
    string: []const u8,
};

const ResponseOptions = struct {
    status: u16 = 200,
    statusText: []const u8 = "",
    // List of header pairs.
    headers: []const []const u8 = &[][].{},
};

pub fn constructor(_input: ?ResponseInput, page: *Page) !Response {
    const arena = page.arena;

    const body = blk: {
        if (_input) |input| {
            switch (input) {
                .string => |str| {
                    break :blk try arena.dupe(u8, str);
                },
            }
        } else {
            break :blk "";
        }
    };

    return .{
        .body = body,
        .headers = &[_][]const u8{},
    };
}

pub fn get_ok(self: *const Response) bool {
    return self.status >= 200 and self.status <= 299;
}

pub fn _text(self: *const Response, page: *Page) !Env.Promise {
    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    try resolver.resolve(self.body);
    return resolver.promise();
}

const testing = @import("../../testing.zig");
test "fetch: response" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();

    try runner.testCases(&.{}, .{});
}
