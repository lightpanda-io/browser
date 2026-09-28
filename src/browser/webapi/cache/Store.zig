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

const URL = @import("../../URL.zig");
const Response = @import("../net/Response.zig");

const Allocator = std.mem.Allocator;

// The Session's CacheStorage data: origin -> named caches -> entries. Plain
// bytes only, no JS objects, so a Response stored by one realm can be served
// to another. Memory only, for the life of the Session.
const Store = @This();

allocator: Allocator,
// origin -> buckets -> url -> Entry
origins: std.StringHashMapUnmanaged(*Origin) = .empty,

pub fn init(allocator: Allocator) Store {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Store) void {
    const allocator = self.allocator;
    var it = self.origins.iterator();
    while (it.next()) |kv| {
        const origin = kv.value_ptr.*;
        for (origin.buckets.values()) |bucket| {
            bucket.deinit(allocator);
        }
        for (origin.deleted.items) |bucket| {
            bucket.deinit(allocator);
        }
        origin.buckets.deinit(allocator);
        origin.deleted.deinit(allocator);
        allocator.destroy(origin);
        allocator.free(kv.key_ptr.*);
    }
    self.origins.deinit(allocator);
}

pub fn forOrigin(self: *Store, origin: []const u8) !*Origin {
    const gop = try self.origins.getOrPut(self.allocator, origin);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }
    errdefer _ = self.origins.remove(origin);

    const owned = try self.allocator.dupe(u8, origin);
    errdefer self.allocator.free(owned);

    const o = try self.allocator.create(Origin);
    o.* = .{ .allocator = self.allocator };

    gop.key_ptr.* = owned;
    gop.value_ptr.* = o;
    return o;
}

pub const Origin = struct {
    allocator: Allocator,
    buckets: std.StringArrayHashMapUnmanaged(*Bucket) = .empty,
    // A Cache object outlives caches.delete, so we need to keep deleted buckets
    deleted: std.ArrayList(*Bucket) = .empty,

    pub fn find(self: *const Origin, name: []const u8) ?*Bucket {
        return self.buckets.get(name);
    }

    pub fn open(self: *Origin, name: []const u8) !*Bucket {
        if (self.find(name)) |bucket| {
            return bucket;
        }
        const allocator = self.allocator;
        try self.buckets.ensureUnusedCapacity(allocator, 1);

        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);

        const bucket = try allocator.create(Bucket);
        bucket.* = .{ .name = owned };
        self.buckets.putAssumeCapacity(owned, bucket);
        return bucket;
    }

    pub fn delete(self: *Origin, name: []const u8) !bool {
        const bucket = self.find(name) orelse return false;
        try self.deleted.append(self.allocator, bucket);
        _ = self.buckets.orderedRemove(name);
        bucket.clear(self.allocator);
        return true;
    }
};

pub const Bucket = struct {
    name: []const u8,
    entries: std.StringArrayHashMapUnmanaged(*Entry) = .empty,

    fn deinit(self: *Bucket, allocator: Allocator) void {
        self.clear(allocator);
        allocator.free(self.name);
        allocator.destroy(self);
    }

    fn clear(self: *Bucket, allocator: Allocator) void {
        for (self.entries.values()) |entry| {
            entry.deinit();
        }
        self.entries.clearAndFree(allocator);
    }

    pub fn match(self: *const Bucket, url: []const u8, ignore_search: bool) ?*const Entry {
        const idx = self.indexOf(url, ignore_search, 0) orelse return null;
        return self.entries.values()[idx];
    }

    pub fn put(self: *Bucket, allocator: Allocator, entry: *Entry) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
        // remove and add, so that it gets placed at the end
        _ = self.delete(entry.url, false);
        self.entries.putAssumeCapacity(entry.url, entry);
    }

    pub fn delete(self: *Bucket, url: []const u8, ignore_search: bool) bool {
        if (ignore_search == false) {
            const idx = self.indexOf(url, ignore_search, 0) orelse return false;
            self.deleteAtIndex(idx);
            return true;
        }

        // when we ignore_search, we can find multiple entries, e.g.:
        // www.example.com/page.js?id=1
        // www.example.com/page.js?id=2
        var deleted = false;
        var last_index: usize = 0;
        while (self.indexOf(url, ignore_search, last_index)) |idx| {
            self.deleteAtIndex(idx);
            deleted = true;
            last_index = idx;
        }
        return deleted;
    }

    fn deleteAtIndex(self: *Bucket, idx: usize) void {
        const entry = self.entries.values()[idx];
        self.entries.orderedRemoveAt(idx);
        entry.deinit();
    }

    fn indexOf(self: *const Bucket, url: []const u8, ignore_search: bool, start: usize) ?usize {
        if (ignore_search == false) {
            return self.entries.getIndex(URL.stripFragment(url));
        }
        const needle = withoutSearch(url);
        for (self.entries.values()[start..], start..) |entry, i| {
            if (std.mem.eql(u8, entry.url_no_search, needle)) {
                return i;
            }
        }
        return null;
    }
};

fn withoutSearch(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len];
}

// A stored request/response pair. Only the request's url is kept: entries are
// always GET and Vary isn't considered.
pub const Entry = struct {
    arena: std.heap.ArenaAllocator,
    status: u16,
    status_text: []const u8,
    is_redirected: bool,
    url: []const u8, // without its fragment.
    url_no_search: []const u8, // slices into url, for ignoreSearch.
    response_url: [:0]const u8,
    response_type: Response.Type,
    headers: []const [2][]const u8,
    body: []const u8,

    pub fn create(allocator: Allocator, url: []const u8) !*Entry {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const owned_url = try arena.allocator().dupe(u8, URL.stripFragment(url));
        const self = try arena.allocator().create(Entry);
        self.* = .{
            .arena = arena,
            .url = owned_url,
            .url_no_search = withoutSearch(owned_url),
            .response_url = "",
            .status = 200,
            .status_text = "",
            .response_type = .default,
            .is_redirected = false,
            .headers = &.{},
            .body = "",
        };
        return self;
    }

    pub fn deinit(self: *Entry) void {
        self.arena.deinit();
    }
};

const testing = @import("../../../testing.zig");
test "Cache - Store: origins and buckets" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const a = try store.forOrigin("https://a.com");
    try testing.expect(a == try store.forOrigin("https://a.com"));
    try testing.expect(a != try store.forOrigin("https://b.com"));

    const v1 = try a.open("v1");
    try testing.expect(v1 == try a.open("v1"));
    _ = try a.open("v2");
    try testing.expectEqual(2, a.buckets.count());

    try v1.put(a.allocator, try testEntry("https://a.com/x", "x"));
    try testing.expectEqual(true, try a.delete("v1"));
    try testing.expectEqual(false, try a.delete("v1"));
    try testing.expectEqual(null, a.find("v1"));

    // a deleted bucket stays usable
    try testing.expectEqual(0, v1.entries.count());
    try v1.put(a.allocator, try testEntry("https://a.com/x", "x"));
}

test "Cache - Store: put, match, delete" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const origin = try store.forOrigin("https://a.com");
    const bucket = try origin.open("v1");

    try bucket.put(origin.allocator, try testEntry("https://a.com/x?a=1", "one"));
    try bucket.put(origin.allocator, try testEntry("https://a.com/x?a=2", "two"));
    try bucket.put(origin.allocator, try testEntry("https://a.com/x?a=1", "three"));
    try testing.expectEqual(2, bucket.entries.count());

    try testing.expectEqual("three", bucket.match("https://a.com/x?a=1#frag", false).?.body);
    try testing.expectEqual(null, bucket.match("https://a.com/x", false));
    try testing.expectEqual("two", bucket.match("https://a.com/x", true).?.body);

    try testing.expectEqual(false, bucket.delete("https://a.com/x", false));
    try testing.expectEqual(true, bucket.delete("https://a.com/x?b=3", true));
    try testing.expectEqual(0, bucket.entries.count());
}

test "Cache - Store: ignoreSearch delete removes every match" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const origin = try store.forOrigin("https://a.com");
    const bucket = try origin.open("v1");

    try bucket.put(origin.allocator, try testEntry("https://a.com/x?a=1", "1"));
    try bucket.put(origin.allocator, try testEntry("https://a.com/x?a=2", "2"));
    try bucket.put(origin.allocator, try testEntry("https://a.com/other", "3"));
    try bucket.put(origin.allocator, try testEntry("https://a.com/x", "4"));
    try bucket.put(origin.allocator, try testEntry("https://a.com/xy?a=1", "5"));
    try bucket.put(origin.allocator, try testEntry("https://a.com/x?a=3#frag", "6"));

    try testing.expectEqual(true, bucket.delete("https://a.com/x?b=1#f", true));
    try testing.expectEqual(2, bucket.entries.count());
    try testing.expectEqual("3", bucket.match("https://a.com/other", false).?.body);
    try testing.expectEqual("5", bucket.match("https://a.com/xy", true).?.body);
    try testing.expectEqual(false, bucket.delete("https://a.com/x", true));
}

fn testEntry(url: []const u8, body: []const u8) !*Entry {
    const entry = try Entry.create(testing.allocator, url);
    errdefer entry.deinit();
    entry.body = try entry.arena.allocator().dupe(u8, body);
    return entry;
}
