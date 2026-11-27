// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const Allocator = std.mem.Allocator;

// A CDP browser's page targets as the server loop sees them, for /json/list
// and /page/{browser_id}/{page_id}. The worker publishes; the loop reads.
const Pages = @This();

pub const Page = struct {
    id: [14]u8,
    url: []const u8,
    title: []const u8,
};

mutex: std.Io.Mutex = .init,
// owned by `allocator`, guarded by mutex
list: std.ArrayList(Page) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) Pages {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Pages) void {
    for (self.list.items) |page| self.freePage(page);
    self.list.deinit(self.allocator);
}

/// Worker thread. Replaces the list; `pages` is copied.
pub fn publish(self: *Pages, pages: []const Page) !void {
    var list: std.ArrayList(Page) = try .initCapacity(self.allocator, pages.len);
    errdefer {
        for (list.items) |page| self.freePage(page);
        list.deinit(self.allocator);
    }
    for (pages) |page| {
        const url = try self.allocator.dupe(u8, page.url);
        errdefer self.allocator.free(url);
        list.appendAssumeCapacity(.{ .id = page.id, .url = url, .title = try self.allocator.dupe(u8, page.title) });
    }

    self.mutex.lockUncancelable(lp.io);
    var old = self.list;
    self.list = list;
    self.mutex.unlock(lp.io);

    for (old.items) |page| self.freePage(page);
    old.deinit(self.allocator);
}

/// Worker thread. Updates a listed page's URL and title. Only the worker
/// changes the list, so it reads it without the lock.
pub fn update(self: *Pages, page: Page) !void {
    const entry = for (self.list.items) |*entry| {
        if (std.mem.eql(u8, &entry.id, &page.id)) break entry;
    } else return;
    if (std.mem.eql(u8, entry.url, page.url) and std.mem.eql(u8, entry.title, page.title)) {
        return;
    }
    const url = try self.allocator.dupe(u8, page.url);
    errdefer self.allocator.free(url);
    const title = try self.allocator.dupe(u8, page.title);

    const old = entry.*;
    self.mutex.lockUncancelable(lp.io);
    entry.url = url;
    entry.title = title;
    self.mutex.unlock(lp.io);
    self.freePage(old);
}

/// Server loop. Whether a page with this target id is listed.
pub fn contains(self: *Pages, id: []const u8) bool {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    for (self.list.items) |page| {
        if (std.mem.eql(u8, &page.id, id)) {
            return true;
        }
    }
    return false;
}

/// Server loop. Writes each page as a /json/list entry; `page_url` is
/// ws://host:port/page/.
pub fn writeJSON(self: *Pages, stringify: *std.json.Stringify, page_url: []const u8, browser_id: []const u8) !void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    for (self.list.items) |*page| {
        var url_buf: [512]u8 = undefined;
        try stringify.write(.{
            .description = "",
            .id = &page.id,
            .title = page.title,
            .type = "page",
            .url = page.url,
            .webSocketDebuggerUrl = try std.mem.print(&url_buf, "{s}{s}/{s}", .{ page_url, browser_id, &page.id }),
        });
    }
}

fn freePage(self: *Pages, page: Page) void {
    self.allocator.free(page.url);
    self.allocator.free(page.title);
}

const testing = std.testing;
test "Pages: publish replaces the list" {
    var pages: Pages = .init(testing.allocator);
    defer pages.deinit();

    try pages.publish(&.{
        .{ .id = "FID-0000000001".*, .url = "http://a/", .title = "A" },
        .{ .id = "FID-0000000002".*, .url = "http://b/", .title = "B" },
    });
    try testing.expect(pages.contains("FID-0000000002"));

    try pages.publish(&.{.{ .id = "FID-0000000003".*, .url = "http://c/", .title = "" }});
    try testing.expect(!pages.contains("FID-0000000001"));
    try testing.expect(pages.contains("FID-0000000003"));
    try testing.expectEqual(1, pages.list.items.len);
    try pages.update(.{ .id = "FID-0000000003".*, .url = "http://d/", .title = "D" });
    try testing.expectEqualStrings("http://d/", pages.list.items[0].url);
    try testing.expectEqualStrings("D", pages.list.items[0].title);
    // not listed: ignored
    try pages.update(.{ .id = "FID-0000000009".*, .url = "http://e/", .title = "" });
    try testing.expectEqual(1, pages.list.items.len);
}
