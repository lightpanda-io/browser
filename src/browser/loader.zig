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
const Client = @import("../http/Client.zig");

const user_agent = @import("browser.zig").user_agent;

pub const Loader = struct {
    client: Client,
    // use 64KB for headers buffer size.
    server_header_buffer: [1024 * 64]u8 = undefined,

    pub const Response = struct {
        alloc: std.mem.Allocator,
        req: *Client.Request,

        pub fn deinit(self: *Response) void {
            self.req.deinit();
            self.alloc.destroy(self.req);
        }
    };

    pub fn init(alloc: std.mem.Allocator) Loader {
        return Loader{
            .client = Client{
                .allocator = alloc,
            },
        };
    }

    pub fn deinit(self: *Loader) void {
        self.client.deinit();
    }

    // see
    // https://ziglang.org/documentation/master/std/#A;std:http.Client.fetch
    // for reference.
    // The caller is responsible for calling `deinit()` on the `Response`.
    pub fn get(self: *Loader, alloc: std.mem.Allocator, uri: std.Uri) !Response {
        var resp = Response{
            .alloc = alloc,
            .req = try alloc.create(Client.Request),
        };
        errdefer alloc.destroy(resp.req);

        resp.req.* = try self.client.open(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "*/*" },
                .{ .name = "Accept-Language", .value = "en-US,en;q=0.5" },
            },
            .server_header_buffer = &self.server_header_buffer,
        });
        errdefer resp.req.deinit();

        try resp.req.send();
        try resp.req.finish();
        try resp.req.wait();

        return resp;
    }
};

test "basic url get" {
    const alloc = std.testing.allocator;
    var loader = Loader.init(alloc);
    defer loader.deinit();

    var result = try loader.get(alloc, "https://en.wikipedia.org/wiki/Main_Page");
    defer result.deinit();

    try std.testing.expect(result.req.response.status == std.http.Status.ok);
}
