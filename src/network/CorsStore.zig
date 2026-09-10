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

const http = @import("http.zig");

const CorsStore = @This();

const Key = struct {
    origin: []const u8,
    target: []const u8,

    fn dupe(self: Key, allocator: std.mem.Allocator) !Key {
        return .{
            .origin = try allocator.dupe(u8, self.origin),
            .target = try allocator.dupe(u8, self.target),
        };
    }

    fn deinit(self: Key, allocator: std.mem.Allocator) void {
        allocator.free(self.origin);
        allocator.free(self.target);
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.origin);
        hasher.update(&.{0});
        hasher.update(key.target);
        return hasher.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return std.ascii.eqlIgnoreCase(a.origin, b.origin) and std.ascii.eqlIgnoreCase(a.target, b.target);
    }
};

const Entry = struct {
    methods_wildcard: bool,
    methods: std.EnumSet(http.Method),

    headers_wildcard: bool,
    headers: []const []const u8,

    expires_at: u64,

    credentials: bool,

    fn unionHeaders(
        allocator: std.mem.Allocator,
        a: []const []const u8,
        b: []const []const u8,
    ) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }

        outerA: for (a) |s| {
            for (list.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, s)) continue :outerA;
            }
            try list.append(allocator, try allocator.dupe(u8, s));
        }
        outerB: for (b) |s| {
            for (list.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, s)) continue :outerB;
            }
            try list.append(allocator, try allocator.dupe(u8, s));
        }

        return list.toOwnedSlice(allocator);
    }

    fn merge(self: Entry, allocator: std.mem.Allocator, new: Entry) !Entry {
        return .{
            .credentials = self.credentials or new.credentials,
            .methods_wildcard = self.methods_wildcard or new.methods_wildcard,
            .methods = self.methods.unionWith(new.methods),
            .headers_wildcard = self.headers_wildcard or new.headers_wildcard,
            .headers = try unionHeaders(allocator, self.headers, new.headers),
            .expires_at = @max(self.expires_at, new.expires_at),
        };
    }

    fn dupe(self: Entry, allocator: std.mem.Allocator) !Entry {
        var new_headers: std.ArrayList([]const u8) = try .initCapacity(allocator, self.headers.len);
        errdefer {
            for (new_headers.items) |hdr| allocator.free(hdr);
            new_headers.deinit(allocator);
        }

        for (self.headers) |hdr| {
            new_headers.appendAssumeCapacity(try allocator.dupe(u8, hdr));
        }

        return .{
            .methods_wildcard = self.methods_wildcard,
            .methods = self.methods,
            .headers_wildcard = self.headers_wildcard,
            .headers = new_headers.items,
            .expires_at = self.expires_at,
            .credentials = self.credentials,
        };
    }

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        for (self.headers) |h| allocator.free(h);
        allocator.free(self.headers);
    }
};

const Map = std.HashMapUnmanaged(Key, Entry, KeyContext, std.hash_map.default_max_load_percentage);

allocator: std.mem.Allocator,
map: Map = .empty,
mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator) CorsStore {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *CorsStore) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    var iter = self.map.iterator();
    while (iter.next()) |entry| {
        entry.key_ptr.deinit(self.allocator);
        entry.value_ptr.deinit(self.allocator);
    }

    self.map.deinit(self.allocator);
}

pub fn get(self: *CorsStore, key: Key) ?Entry {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    const entry = self.map.get(key) orelse return null;

    if (entry.expires_at <= lp.datetime.milliTimestamp(.real)) {
        const kv = self.map.fetchRemove(key).?;
        kv.key.deinit(self.allocator);
        kv.value.deinit(self.allocator);
        return null;
    }

    return entry;
}

/// Insert or merge a CORS grant for (origin, target). `entry` is not
/// consumed: `put` copies whatever it needs (via `dupe`/`merge`, which
/// always allocate their own copies) and never takes ownership of
/// `entry.headers` or its contents.
///
/// Callers remain responsible for
/// freeing `entry.headers` after this call, on both the insert and
/// the merge path.
pub fn put(self: *CorsStore, key: Key, entry: Entry) !void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    const gop = try self.map.getOrPut(self.allocator, key);
    if (!gop.found_existing) {
        errdefer _ = self.map.remove(key);
        gop.key_ptr.* = try key.dupe(self.allocator);
        gop.value_ptr.* = try entry.dupe(self.allocator);
        return;
    }

    const old = gop.value_ptr.*;
    const merged = old.merge(self.allocator, entry) catch |err| {
        return err;
    };
    old.deinit(self.allocator);
    gop.value_ptr.* = merged;
}

pub fn covers(
    entry: Entry,
    method: http.Method,
    wants_credentials: bool,
    authored_headers: []const []const u8,
) bool {
    if (wants_credentials and !entry.credentials) {
        return false;
    }

    if (!entry.methods_wildcard and !entry.methods.contains(method)) {
        return false;
    }

    for (authored_headers) |name| {
        const is_authorization = std.ascii.eqlIgnoreCase(name, "authorization");
        if (entry.headers_wildcard and !is_authorization) continue;

        var found = false;
        for (entry.headers) |allowed| {
            if (std.ascii.eqlIgnoreCase(allowed, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    return true;
}

const testing = @import("../testing.zig");

fn freeHeaders(allocator: std.mem.Allocator, headers: []const []const u8) void {
    for (headers) |h| allocator.free(h);
    allocator.free(headers);
}

test "CorsStore: put then get, miss on different origin/target" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator);
    defer store.deinit();

    const headers = try allocator.alloc([]const u8, 1);
    headers[0] = try allocator.dupe(u8, "x-custom");
    defer freeHeaders(allocator, headers);

    try store.put(.{ .origin = "https://a.example", .target = "https://api.example" }, .{
        .credentials = false,
        .methods_wildcard = false,
        .methods = std.EnumSet(http.Method).initOne(.POST),
        .headers_wildcard = false,
        .headers = headers,
        .expires_at = lp.datetime.milliTimestamp(.real) + 60_000,
    });

    // store.get returns the store's own copy — not caller-owned, don't free it.
    const hit = store.get(.{ .origin = "https://a.example", .target = "https://api.example" }).?;
    try testing.expect(hit.methods.contains(.POST));
    try testing.expect(!hit.methods.contains(.GET));

    try testing.expectEqual(null, store.get(.{ .origin = "https://b.example", .target = "https://api.example" }));
    try testing.expectEqual(null, store.get(.{ .origin = "https://a.example", .target = "https://other.example" }));
}

test "CorsStore: expired entries are evicted on get" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator);
    defer store.deinit();

    try store.put(.{ .origin = "https://a.example", .target = "https://api.example" }, .{
        .credentials = false,
        .methods_wildcard = true,
        .methods = .initEmpty(),
        .headers_wildcard = true,
        .headers = &.{}, // empty slice, nothing to free
        .expires_at = lp.datetime.milliTimestamp(.real) - 1,
    });

    try testing.expectEqual(null, store.get(.{ .origin = "https://a.example", .target = "https://api.example" }));
    try testing.expectEqual(0, store.map.count());
}

test "CorsStore: put merges into existing entry rather than clobbering" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator);
    defer store.deinit();

    const key = Key{ .origin = "https://a.example", .target = "https://api.example" };

    const h1 = try allocator.alloc([]const u8, 1);
    h1[0] = try allocator.dupe(u8, "x-one");
    try store.put(key, .{
        .credentials = false,
        .methods_wildcard = false,
        .methods = std.EnumSet(http.Method).initOne(.POST),
        .headers_wildcard = false,
        .headers = h1,
        .expires_at = lp.datetime.milliTimestamp(.real) + 60_000,
    });
    freeHeaders(allocator, h1);

    const h2 = try allocator.alloc([]const u8, 1);
    h2[0] = try allocator.dupe(u8, "x-two");
    try store.put(key, .{
        .credentials = false,
        .methods_wildcard = false,
        .methods = std.EnumSet(http.Method).initOne(.PUT),
        .headers_wildcard = false,
        .headers = h2,
        .expires_at = lp.datetime.milliTimestamp(.real) + 60_000,
    });
    freeHeaders(allocator, h2);

    const merged = store.get(key).?;
    try testing.expect(merged.methods.contains(.POST));
    try testing.expect(merged.methods.contains(.PUT));
    try testing.expectEqual(2, merged.headers.len);

    try testing.expect(CorsStore.covers(merged, .POST, false, &.{"x-one"}));
    try testing.expect(CorsStore.covers(merged, .PUT, false, &.{"x-two"}));
    try testing.expect(!CorsStore.covers(merged, .DELETE, false, &.{}));
}

test "CorsStore: covers rejects credentialed request against uncredentialed wildcard" {
    const entry = CorsStore.Entry{
        .credentials = false,
        .methods_wildcard = true,
        .methods = .initEmpty(),
        .headers_wildcard = true,
        .headers = &.{},
        .expires_at = std.math.maxInt(u64),
    };
    try testing.expect(!CorsStore.covers(entry, .GET, true, &.{}));
    try testing.expect(CorsStore.covers(entry, .GET, false, &.{}));
}

test "CorsStore: covers never lets a wildcard cover Authorization" {
    const entry = CorsStore.Entry{
        .credentials = false,
        .methods_wildcard = true,
        .methods = .initEmpty(),
        .headers_wildcard = true,
        .headers = &.{},
        .expires_at = std.math.maxInt(u64),
    };
    try testing.expect(!CorsStore.covers(entry, .GET, false, &.{"authorization"}));
    try testing.expect(CorsStore.covers(entry, .GET, false, &.{"x-anything"}));
}
