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

const builtin = @import("builtin");
const jsruntime = @import("jsruntime");

const URL = @import("../url/url.zig").URL;

const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-location-interface
pub const Location = struct {
    pub const mem_guarantied = true;

    url: ?*URL = null,

    pub fn deinit(_: *Location, _: std.mem.Allocator) void {}

    pub fn get_href(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        if (self.url) |u| return u.get_href(alloc);

        return "";
    }

    pub fn get_protocol(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        if (self.url) |u| return u.get_protocol(alloc);

        return "";
    }

    pub fn get_host(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        if (self.url) |u| return u.get_host(alloc);

        return "";
    }

    pub fn get_hostname(self: *Location) []const u8 {
        if (self.url) |u| return u.get_hostname();

        return "";
    }

    pub fn get_port(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        if (self.url) |u| return u.get_port(alloc);

        return "";
    }

    pub fn get_pathname(self: *Location) []const u8 {
        if (self.url) |u| return u.get_pathname();

        return "";
    }

    pub fn get_search(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        if (self.url) |u| return u.get_search(alloc);

        return "";
    }

    pub fn get_hash(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        if (self.url) |u| return u.get_hash(alloc);

        return "";
    }

    pub fn get_origin(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        if (self.url) |u| return u.get_origin(alloc);

        return "";
    }

    // TODO
    pub fn _assign(_: *Location, url: []const u8) !void {
        _ = url;
    }

    // TODO
    pub fn _replace(_: *Location, url: []const u8) !void {
        _ = url;
    }

    // TODO
    pub fn _reload(_: *Location) !void {}

    pub fn _toString(self: *Location, alloc: std.mem.Allocator) ![]const u8 {
        return try self.get_href(alloc);
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var location = [_]Case{
        .{ .src = "location.href", .ex = "https://lightpanda.io/opensource-browser/" },
        .{ .src = "document.location.href", .ex = "https://lightpanda.io/opensource-browser/" },

        .{ .src = "location.host", .ex = "lightpanda.io" },
        .{ .src = "location.hostname", .ex = "lightpanda.io" },
        .{ .src = "location.origin", .ex = "https://lightpanda.io" },
        .{ .src = "location.pathname", .ex = "/opensource-browser/" },
        .{ .src = "location.hash", .ex = "" },
        .{ .src = "location.port", .ex = "" },
        .{ .src = "location.search", .ex = "" },
    };
    try checkCases(js_env, &location);
}
