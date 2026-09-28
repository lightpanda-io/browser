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
const isSafelistedMethod = @import("CorsGate.zig").isSafelistedMethod;
const ClockCache = @import("ClockCache.zig").ClockCache;

const CorsStore = @This();

pub const Key = struct {
    origin: []const u8,
    target: []const u8,
    credentials: bool,

    /// Serializes into a single string suitable as a ClockCache key.
    fn build(self: Key, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, self.origin);
        try buf.append(allocator, 0);
        try buf.appendSlice(allocator, self.target);
        try buf.append(allocator, 0);
        try buf.append(allocator, @intFromBool(self.credentials));

        return buf.toOwnedSlice(allocator);
    }
};

pub const Entry = struct {
    methods_wildcard: bool,
    methods: std.EnumSet(http.Method),

    headers_wildcard: bool,
    headers: []const []const u8,

    expires_at: u64,

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
            .methods_wildcard = self.methods_wildcard or new.methods_wildcard,
            .methods = self.methods.unionWith(new.methods),
            .headers_wildcard = self.headers_wildcard or new.headers_wildcard,
            .headers = try unionHeaders(allocator, self.headers, new.headers),
            .expires_at = @min(self.expires_at, new.expires_at),
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
        };
    }

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        for (self.headers) |h| allocator.free(h);
        allocator.free(self.headers);
    }
};

allocator: std.mem.Allocator,
map: ClockCache(Entry),
mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator, capacity: usize) CorsStore {
    return .{ .allocator = allocator, .map = .init(allocator, capacity) };
}

pub fn deinit(self: *CorsStore) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    for (self.map.entries()) |*entry| {
        entry.value.deinit(self.allocator);
    }
    self.map.deinit();
}

// Caller is expected to be holding mutex.
fn getWithExpiration(self: *CorsStore, cache_key: []const u8) ?*Entry {
    const entry = self.map.get(cache_key) orelse return null;

    if (entry.expires_at <= lp.datetime.milliTimestamp(.real)) {
        if (self.map.remove(cache_key)) |e| {
            e.deinit(self.allocator);
        }

        return null;
    }

    return entry;
}

fn matches(entry: Entry, method: http.Method, authored_headers: []const []const u8) bool {
    if (!isSafelistedMethod(method) and !entry.methods_wildcard and !entry.methods.contains(method)) {
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

pub fn coversRequest(
    self: *CorsStore,
    allocator: std.mem.Allocator,
    key: Key,
    method: http.Method,
    authored_headers: []const []const u8,
) !bool {
    const primary_key = try key.build(allocator);
    defer allocator.free(primary_key);

    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    if (self.getWithExpiration(primary_key)) |entry| {
        if (matches(entry.*, method, authored_headers)) return true;
    }

    if (key.credentials) return false;

    const cred_key = try (Key{ .origin = key.origin, .target = key.target, .credentials = true }).build(allocator);
    defer allocator.free(cred_key);

    const entry = self.getWithExpiration(cred_key) orelse return false;
    return matches(entry.*, method, authored_headers);
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
    const cache_key = try key.build(self.allocator);
    defer self.allocator.free(cache_key);

    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    if (self.getWithExpiration(cache_key)) |existing| {
        const merged = try existing.merge(self.allocator, entry);
        existing.deinit(self.allocator);
        existing.* = merged;
        return;
    }

    const owned_entry = try entry.dupe(self.allocator);
    errdefer owned_entry.deinit(self.allocator);

    switch (try self.map.insert(cache_key, owned_entry)) {
        .exists => unreachable,
        .inserted => |evicted| {
            if (evicted) |v| {
                var e = v;
                e.deinit(self.allocator);
            }
        },
    }
}

const testing = @import("../testing.zig");

fn freeHeaders(allocator: std.mem.Allocator, headers: []const []const u8) void {
    for (headers) |h| allocator.free(h);
    allocator.free(headers);
}

test "CorsStore: put then covers, miss on different origin/target/credentials" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator, 10);
    defer store.deinit();

    const headers = try allocator.alloc([]const u8, 1);
    headers[0] = try allocator.dupe(u8, "x-custom");
    defer freeHeaders(allocator, headers);

    try store.put(.{ .origin = "https://a.example", .target = "https://api.example", .credentials = false }, .{
        .methods_wildcard = false,
        .methods = std.EnumSet(http.Method).initOne(.POST),
        .headers_wildcard = false,
        .headers = headers,
        .expires_at = lp.datetime.milliTimestamp(.real) + 60_000,
    });

    try testing.expect(try store.coversRequest(
        allocator,
        .{ .origin = "https://a.example", .target = "https://api.example", .credentials = false },
        .POST,
        &.{},
    ));
    try testing.expect(!try store.coversRequest(
        allocator,
        .{ .origin = "https://a.example", .target = "https://api.example", .credentials = false },
        .PUT,
        &.{},
    ));

    try testing.expect(!try store.coversRequest(
        allocator,
        .{ .origin = "https://b.example", .target = "https://api.example", .credentials = false },
        .POST,
        &.{},
    ));
    try testing.expect(!try store.coversRequest(
        allocator,
        .{ .origin = "https://a.example", .target = "https://other.example", .credentials = false },
        .POST,
        &.{},
    ));

    // Same origin/target but different credentials mode: separate entry, must miss.
    try testing.expect(!try store.coversRequest(
        allocator,
        .{ .origin = "https://a.example", .target = "https://api.example", .credentials = true },
        .POST,
        &.{},
    ));
}

test "CorsStore: expired entries are treated as a miss on covers" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator, 10);
    defer store.deinit();

    try store.put(.{ .origin = "https://a.example", .target = "https://api.example", .credentials = false }, .{
        .methods_wildcard = true,
        .methods = .initEmpty(),
        .headers_wildcard = true,
        .headers = &.{}, // empty slice, nothing to free
        .expires_at = lp.datetime.milliTimestamp(.real) - 1,
    });

    try testing.expect(!try store.coversRequest(
        allocator,
        .{ .origin = "https://a.example", .target = "https://api.example", .credentials = false },
        .GET,
        &.{},
    ));
}

test "CorsStore: put merges into existing entry rather than clobbering" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator, 10);
    defer store.deinit();

    const key = Key{ .origin = "https://a.example", .target = "https://api.example", .credentials = false };

    const h1 = try allocator.alloc([]const u8, 1);
    h1[0] = try allocator.dupe(u8, "x-one");
    try store.put(key, .{
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
        .methods_wildcard = false,
        .methods = std.EnumSet(http.Method).initOne(.PUT),
        .headers_wildcard = false,
        .headers = h2,
        .expires_at = lp.datetime.milliTimestamp(.real) + 60_000,
    });
    freeHeaders(allocator, h2);

    try testing.expect(try store.coversRequest(allocator, key, .POST, &.{"x-one"}));
    try testing.expect(try store.coversRequest(allocator, key, .PUT, &.{"x-two"}));
    try testing.expect(!try store.coversRequest(allocator, key, .DELETE, &.{}));
}

test "CorsStore: credentialed and non-credentialed grants for same origin/target stay separate" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator, 10);
    defer store.deinit();

    const origin = "https://a.example";
    const target = "https://api.example";

    // Non-credentialed grant: wildcard headers allowed (valid per spec for non-cred requests).
    try store.put(.{ .origin = origin, .target = target, .credentials = false }, .{
        .methods_wildcard = true,
        .methods = .initEmpty(),
        .headers_wildcard = true,
        .headers = &.{},
        .expires_at = lp.datetime.milliTimestamp(.real) + 60_000,
    });

    // Credentialed grant: explicit methods/headers only, no wildcard.
    const h = try allocator.alloc([]const u8, 1);
    h[0] = try allocator.dupe(u8, "x-custom");
    try store.put(.{ .origin = origin, .target = target, .credentials = true }, .{
        .methods_wildcard = false,
        .methods = std.EnumSet(http.Method).initOne(.GET),
        .headers_wildcard = false,
        .headers = h,
        .expires_at = lp.datetime.milliTimestamp(.real) + 60_000,
    });
    freeHeaders(allocator, h);

    // A credentialed request asking for an arbitrary header must be rejected
    // against the credentialed entry, even though the non-cred entry has a wildcard.
    try testing.expect(!try store.coversRequest(
        allocator,
        .{ .origin = origin, .target = target, .credentials = true },
        .GET,
        &.{"x-anything"},
    ));
    try testing.expect(try store.coversRequest(
        allocator,
        .{ .origin = origin, .target = target, .credentials = true },
        .GET,
        &.{"x-custom"},
    ));
    try testing.expect(!try store.coversRequest(
        allocator,
        .{ .origin = origin, .target = target, .credentials = true },
        .PUT,
        &.{},
    ));

    // The non-credentialed entry's wildcard still works for non-cred requests.
    try testing.expect(try store.coversRequest(allocator, .{ .origin = origin, .target = target, .credentials = false }, .GET, &.{"x-anything"}));
}

test "CorsStore: covers never lets a wildcard cover Authorization" {
    const allocator = testing.allocator;
    var store = CorsStore.init(allocator, 10);
    defer store.deinit();

    const key = Key{ .origin = "https://a.example", .target = "https://api.example", .credentials = false };
    try store.put(key, .{
        .methods_wildcard = true,
        .methods = .initEmpty(),
        .headers_wildcard = true,
        .headers = &.{},
        .expires_at = std.math.maxInt(u64),
    });

    try testing.expect(!try store.coversRequest(allocator, key, .GET, &.{"authorization"}));
    try testing.expect(try store.coversRequest(allocator, key, .GET, &.{"x-anything"}));
}
