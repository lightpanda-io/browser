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

const SessionState = @import("../env.zig").SessionState;

const builtin = @import("builtin");
const jsruntime = @import("jsruntime");

const URL = @import("../url/url.zig").URL;

const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-location-interface
pub const Location = struct {
    url: ?URL = null,

    pub fn get_href(self: *Location, state: *SessionState) ![]const u8 {
        if (self.url) |*u| return u.get_href(state);
        return "";
    }

    pub fn get_protocol(self: *Location, state: *SessionState) ![]const u8 {
        if (self.url) |*u| return u.get_protocol(state);
        return "";
    }

    pub fn get_host(self: *Location, state: *SessionState) ![]const u8 {
        if (self.url) |*u| return u.get_host(state);
        return "";
    }

    pub fn get_hostname(self: *Location) []const u8 {
        if (self.url) |*u| return u.get_hostname();
        return "";
    }

    pub fn get_port(self: *Location, state: *SessionState) ![]const u8 {
        if (self.url) |*u| return u.get_port(state);
        return "";
    }

    pub fn get_pathname(self: *Location) []const u8 {
        if (self.url) |*u| return u.get_pathname();
        return "";
    }

    pub fn get_search(self: *Location, state: *SessionState) ![]const u8 {
        if (self.url) |*u| return u.get_search(state);
        return "";
    }

    pub fn get_hash(self: *Location, state: *SessionState) ![]const u8 {
        if (self.url) |*u| return u.get_hash(state);
        return "";
    }

    pub fn get_origin(self: *Location, state: *SessionState) ![]const u8 {
        if (self.url) |*u| return u.get_origin(state);
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

    pub fn _toString(self: *Location, state: *SessionState) ![]const u8 {
        return try self.get_href(state);
    }
};

const testing = @import("../../testing.zig");
test "Browser.HTML.Location" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "location.href", "https://lightpanda.io/opensource-browser/" },
        .{ "document.location.href", "https://lightpanda.io/opensource-browser/" },

        .{ "location.host", "lightpanda.io" },
        .{ "location.hostname", "lightpanda.io" },
        .{ "location.origin", "https://lightpanda.io" },
        .{ "location.pathname", "/opensource-browser/" },
        .{ "location.hash", "" },
        .{ "location.port", "" },
        .{ "location.search", "" },
    }, .{});
}
