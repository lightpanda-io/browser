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

const Page = @import("../page.zig").Page;

const URL = @import("../url/url.zig").URL;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-location-interface
pub const Location = struct {
    url: ?URL = null,

    pub fn get_href(self: *Location, page: *Page) ![]const u8 {
        if (self.url) |*u| return u.get_href(page);
        return "";
    }

    pub fn get_protocol(self: *Location, page: *Page) ![]const u8 {
        if (self.url) |*u| return u.get_protocol(page);
        return "";
    }

    pub fn get_host(self: *Location, page: *Page) ![]const u8 {
        if (self.url) |*u| return u.get_host(page);
        return "";
    }

    pub fn get_hostname(self: *Location) []const u8 {
        if (self.url) |*u| return u.get_hostname();
        return "";
    }

    pub fn get_port(self: *Location, page: *Page) ![]const u8 {
        if (self.url) |*u| return u.get_port(page);
        return "";
    }

    pub fn get_pathname(self: *Location) []const u8 {
        if (self.url) |*u| return u.get_pathname();
        return "";
    }

    pub fn get_search(self: *Location, page: *Page) ![]const u8 {
        if (self.url) |*u| return u.get_search(page);
        return "";
    }

    pub fn get_hash(self: *Location, page: *Page) ![]const u8 {
        if (self.url) |*u| return u.get_hash(page);
        return "";
    }

    pub fn get_origin(self: *Location, page: *Page) ![]const u8 {
        if (self.url) |*u| return u.get_origin(page);
        return "";
    }

    pub fn _assign(_: *const Location, url: []const u8, page: *Page) !void {
        return page.navigateFromWebAPI(url, .{ .reason = .script });
    }

    pub fn _replace(_: *const Location, url: []const u8, page: *Page) !void {
        return page.navigateFromWebAPI(url, .{ .reason = .script });
    }

    pub fn _reload(_: *const Location, page: *Page) !void {
        return page.navigateFromWebAPI(page.url.raw, .{ .reason = .script });
    }

    pub fn _toString(self: *Location, page: *Page) ![]const u8 {
        return try self.get_href(page);
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.Location" {
    try testing.htmlRunner("html/location.html");
}
