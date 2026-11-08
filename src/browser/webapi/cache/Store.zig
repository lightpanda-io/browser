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

    pub fn match(
        self: *const Bucket,
        url: []const u8,
        ignore_search: bool,
        request_headers: []const [2][]const u8,
        ignore_vary: bool,
    ) ?*const Entry {
        const idx = self.indexOf(url, ignore_search, 0) orelse return null;
        const entry = self.entries.values()[idx];
        if (ignore_vary == false and varyMatches(entry, request_headers) == false) {
            return null;
        }
        return entry;
    }

    pub fn put(self: *Bucket, allocator: Allocator, entry: *Entry) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
        // remove and add, so that it gets placed at the end; put replaces by
        // url regardless of any Vary the old entry was stored under
        _ = self.delete(entry.url, false, &.{}, true);
        self.entries.putAssumeCapacity(entry.url, entry);
    }

    pub fn delete(
        self: *Bucket,
        url: []const u8,
        ignore_search: bool,
        request_headers: []const [2][]const u8,
        ignore_vary: bool,
    ) bool {
        if (ignore_search == false) {
            const idx = self.indexOf(url, ignore_search, 0) orelse return false;
            if (ignore_vary == false and varyMatches(self.entries.values()[idx], request_headers) == false) {
                return false;
            }
            self.deleteAtIndex(idx);
            return true;
        }

        // when we ignore_search, we can find multiple entries, e.g.:
        // www.example.com/page.js?id=1
        // www.example.com/page.js?id=2
        var deleted = false;
        var last_index: usize = 0;
        while (self.indexOf(url, ignore_search, last_index)) |idx| {
            if (ignore_vary or varyMatches(self.entries.values()[idx], request_headers)) {
                self.deleteAtIndex(idx);
                deleted = true;
                // the next match slides into this slot after the removal
                last_index = idx;
            } else {
                last_index = idx + 1;
            }
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
    return url[0 .. std.mem.findAny(u8, url, "?#") orelse url.len];
}

// A stored request/response pair. Entries are always GET; the request headers
// named by the response's Vary are captured at put time so lookups can match
// them.
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
    // The request headers named by the response's Vary, captured at put time.
    vary_headers: []const VaryHeader = &.{},
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

// A request header named by the stored response's Vary. `value` is null when
// the storing request didn't have the header; two lookups which both lack the
// header still match.
pub const VaryHeader = struct {
    name: []const u8,
    value: ?[]const u8,
};

// Whether the entry's Vary matches the requesting headers: every field name
// in the stored Vary must be absent from both sides, or present with a
// matching (byte-case-insensitive) value on both sides.
fn varyMatches(entry: *const Entry, request_headers: []const [2][]const u8) bool {
    for (entry.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header[0], "vary") == false) {
            continue;
        }
        var it = std.mem.splitScalar(u8, header[1], ',');
        while (it.next()) |field| {
            const name = std.mem.trim(u8, field, " \t");
            if (name.len == 0) {
                continue;
            }
            // An entry stored with `Vary: *` would never match; store-time
            // rejects it, but stay defensive.
            if (std.mem.eql(u8, name, "*")) {
                return false;
            }
            const stored = varyValue(entry.vary_headers, name) orelse return false;
            const actual = headerValue(request_headers, name);
            if (stored) |stored_value| {
                const actual_value = actual orelse return false;
                if (std.ascii.eqlIgnoreCase(stored_value, actual_value) == false) {
                    return false;
                }
            } else if (actual != null) {
                return false;
            }
        }
    }
    return true;
}

fn varyValue(vary_headers: []const VaryHeader, name: []const u8) ??[]const u8 {
    for (vary_headers) |*vary| {
        if (std.ascii.eqlIgnoreCase(vary.name, name)) {
            return vary.value;
        }
    }
    return null;
}

fn headerValue(headers: []const [2][]const u8, name: []const u8) ?[]const u8 {
    for (headers) |kv| {
        if (std.ascii.eqlIgnoreCase(kv[0], name)) {
            return kv[1];
        }
    }
    return null;
}

// The request headers named by the response's Vary, captured at put time so
// that lookups can compare them. A name the request doesn't carry is stored
// with a null value.
pub fn captureVaryHeaders(
    allocator: Allocator,
    response_headers: []const [2][]const u8,
    request_headers: []const [2][]const u8,
) ![]const VaryHeader {
    var vary: std.ArrayList(VaryHeader) = .empty;
    for (response_headers) |header| {
        if (std.ascii.eqlIgnoreCase(header[0], "vary") == false) {
            continue;
        }
        var it = std.mem.splitScalar(u8, header[1], ',');
        while (it.next()) |field| {
            const name = std.mem.trim(u8, field, " \t");
            if (name.len == 0 or std.mem.eql(u8, name, "*")) {
                // `Vary: *` is rejected at store time.
                continue;
            }
            try vary.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .value = if (headerValue(request_headers, name)) |value|
                    try allocator.dupe(u8, value)
                else
                    null,
            });
        }
    }
    return vary.items;
}

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

    try testing.expectEqual("three", bucket.match("https://a.com/x?a=1#frag", false, &.{}, false).?.body);
    try testing.expectEqual(null, bucket.match("https://a.com/x", false, &.{}, false));
    try testing.expectEqual("two", bucket.match("https://a.com/x", true, &.{}, false).?.body);

    try testing.expectEqual(false, bucket.delete("https://a.com/x", false, &.{}, false));
    try testing.expectEqual(true, bucket.delete("https://a.com/x?b=3", true, &.{}, false));
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

    try testing.expectEqual(true, bucket.delete("https://a.com/x?b=1#f", true, &.{}, false));
    try testing.expectEqual(2, bucket.entries.count());
    try testing.expectEqual("3", bucket.match("https://a.com/other", false, &.{}, false).?.body);
    try testing.expectEqual("5", bucket.match("https://a.com/xy", true, &.{}, false).?.body);
    try testing.expectEqual(false, bucket.delete("https://a.com/x", true, &.{}, false));
}

test "Cache - Store: match honours Vary" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const origin = try store.forOrigin("https://a.com");
    const bucket = try origin.open("v1");

    const entry = try testEntry("https://a.com/x", "one");
    entry.headers = try entry.arena.allocator().dupe([2][]const u8, &.{.{ "vary", "Accept-Language" }});
    entry.vary_headers = try entry.arena.allocator().dupe(VaryHeader, &.{.{ .name = "Accept-Language", .value = "fr" }});
    try bucket.put(origin.allocator, entry);

    const fr = [2][]const u8{ "Accept-Language", "fr" };
    const en = [2][]const u8{ "accept-language", "en" };

    // same value (name compared case-insensitively) matches
    try testing.expectEqual("one", bucket.match("https://a.com/x", false, &.{fr}, false).?.body);
    // a different value doesn't
    try testing.expectEqual(null, bucket.match("https://a.com/x", false, &.{en}, false));
    // a request without the header doesn't
    try testing.expectEqual(null, bucket.match("https://a.com/x", false, &.{}, false));
    // ...unless the lookup ignores Vary
    try testing.expectEqual("one", bucket.match("https://a.com/x", false, &.{en}, true).?.body);

    // delete honours Vary too
    try testing.expectEqual(false, bucket.delete("https://a.com/x", false, &.{en}, false));
    try testing.expectEqual(true, bucket.delete("https://a.com/x", false, &.{fr}, false));
    try testing.expectEqual(0, bucket.entries.count());
}

test "Cache - Store: match honours every Vary field name" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const origin = try store.forOrigin("https://a.com");
    const bucket = try origin.open("v1");

    const entry = try testEntry("https://a.com/x", "one");
    entry.headers = try entry.arena.allocator().dupe([2][]const u8, &.{.{ "vary", "Accept-Language, User-Agent" }});
    entry.vary_headers = try entry.arena.allocator().dupe(VaryHeader, &.{
        .{ .name = "Accept-Language", .value = "fr" },
        .{ .name = "User-Agent", .value = "agent/1" },
    });
    try bucket.put(origin.allocator, entry);

    // Accept-Language matches case-insensitively, but the lookup is missing
    // the second Vary'd header, so it still doesn't match.
    const both = [2][]const u8{ "accept-language", "FR" };
    try testing.expectEqual(null, bucket.match("https://a.com/x", false, &.{both}, false));

    const both_ok = [_][2][]const u8{ .{ "accept-language", "fr" }, .{ "user-agent", "agent/1" } };
    try testing.expectEqual("one", bucket.match("https://a.com/x", false, &.{ both_ok[0], both_ok[1] }, false).?.body);
}

test "Cache - Store: match when both requests lack the Vary header" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const origin = try store.forOrigin("https://a.com");
    const bucket = try origin.open("v1");

    // The storing request didn't carry the Vary'd header either.
    const entry = try testEntry("https://a.com/x", "one");
    entry.headers = try entry.arena.allocator().dupe([2][]const u8, &.{.{ "vary", "Accept-Language" }});
    entry.vary_headers = try entry.arena.allocator().dupe(VaryHeader, &.{.{ .name = "Accept-Language", .value = null }});
    try bucket.put(origin.allocator, entry);

    // A lookup without the header matches (both sides lack it)...
    try testing.expectEqual("one", bucket.match("https://a.com/x", false, &.{}, false).?.body);
    // ...but a lookup that does carry it doesn't.
    const fr = [2][]const u8{ "Accept-Language", "fr" };
    try testing.expectEqual(null, bucket.match("https://a.com/x", false, &.{fr}, false));
}

fn testEntry(url: []const u8, body: []const u8) !*Entry {
    const entry = try Entry.create(testing.allocator, url);
    errdefer entry.deinit();
    entry.body = try entry.arena.allocator().dupe(u8, body);
    return entry;
}
