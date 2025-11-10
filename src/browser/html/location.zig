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
const Page = @import("../page.zig").Page;
const URL = @import("../url/url.zig").URL;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-location-interface
pub const Location = struct {
    url: URL,

    /// Initializes the `Location` to be used in `Window`.
    /// Browsers give such initial values when user not navigated yet:
    /// Chrome  -> chrome://new-tab-page/
    /// Firefox -> about:newtab
    /// Safari  -> favorites://
    pub fn init(url: []const u8) !Location {
        return .{ .url = try .initForLocation(url) };
    }

    pub fn get_href(self: *Location, page: *Page) ![]const u8 {
        return self.url.get_href(page);
    }

    pub fn set_href(_: *const Location, href: []const u8, page: *Page) !void {
        return page.navigateFromWebAPI(href, .{ .reason = .script }, .{ .push = null });
    }

    pub fn set_hash(_: *const Location, hash: []const u8, page: *Page) !void {
        const normalized_hash = blk: {
            if (hash.len == 0) {
                const old_url = page.url.raw;

                break :blk if (std.mem.indexOfScalar(u8, old_url, '#')) |index|
                    old_url[0..index]
                else
                    old_url;
            } else if (hash[0] == '#')
                break :blk hash
            else
                break :blk try std.fmt.allocPrint(page.arena, "#{s}", .{hash});
        };

        return page.navigateFromWebAPI(normalized_hash, .{ .reason = .script }, .replace);
    }

    pub fn get_protocol(self: *Location) []const u8 {
        return self.url.get_protocol();
    }

    pub fn get_host(self: *Location) []const u8 {
        return self.url.get_host();
    }

    pub fn get_hostname(self: *Location) []const u8 {
        return self.url.get_hostname();
    }

    pub fn get_port(self: *Location) []const u8 {
        return self.url.get_port();
    }

    pub fn get_pathname(self: *Location) []const u8 {
        return self.url.get_pathname();
    }

    pub fn get_search(self: *Location, page: *Page) ![]const u8 {
        return self.url.get_search(page);
    }

    pub fn get_hash(self: *Location) []const u8 {
        return self.url.get_hash();
    }

    pub fn get_origin(self: *Location, page: *Page) ![]const u8 {
        return self.url.get_origin(page);
    }

    pub fn _assign(_: *const Location, url: []const u8, page: *Page) !void {
        return page.navigateFromWebAPI(url, .{ .reason = .script }, .{ .push = null });
    }

    pub fn _replace(_: *const Location, url: []const u8, page: *Page) !void {
        return page.navigateFromWebAPI(url, .{ .reason = .script }, .replace);
    }

    pub fn _reload(_: *const Location, page: *Page) !void {
        return page.navigateFromWebAPI(page.url.raw, .{ .reason = .script }, .reload);
    }

    pub fn _toString(self: *Location, page: *Page) ![]const u8 {
        return self.get_href(page);
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.Location" {
    try testing.htmlRunner("html/location.html");
}
