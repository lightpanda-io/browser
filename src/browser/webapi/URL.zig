// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");

const U = @import("../URL.zig");
const Page = @import("../Page.zig");
const URLSearchParams = @import("net/URLSearchParams.zig");
const Blob = @import("Blob.zig");

const Allocator = std.mem.Allocator;

const URL = @This();

_raw: [:0]const u8,
_arena: ?Allocator = null,
_search_params: ?*URLSearchParams = null,

// convenience
pub const resolve = @import("../URL.zig").resolve;
pub const eqlDocument = @import("../URL.zig").eqlDocument;

pub fn init(url: [:0]const u8, base_: ?[:0]const u8, page: *Page) !*URL {
    const url_is_absolute = @import("../URL.zig").isCompleteHTTPUrl(url);

    const base = if (base_) |b| blk: {
        // If URL is absolute, base is ignored (but we still use page.url internally)
        if (url_is_absolute) {
            break :blk page.url;
        }
        // For relative URLs, base must be a valid absolute URL
        if (!@import("../URL.zig").isCompleteHTTPUrl(b)) {
            return error.TypeError;
        }
        break :blk b;
    } else if (!url_is_absolute) {
        return error.TypeError;
    } else page.url;

    const arena = page.arena;
    const raw = try resolve(arena, base, url, .{ .always_dupe = true });

    return page._factory.create(URL{
        ._raw = raw,
        ._arena = arena,
    });
}

pub fn getUsername(self: *const URL) []const u8 {
    return U.getUsername(self._raw);
}

pub fn getPassword(self: *const URL) []const u8 {
    return U.getPassword(self._raw);
}

pub fn getPathname(self: *const URL) []const u8 {
    return U.getPathname(self._raw);
}

pub fn getProtocol(self: *const URL) []const u8 {
    return U.getProtocol(self._raw);
}

pub fn getHostname(self: *const URL) []const u8 {
    return U.getHostname(self._raw);
}

pub fn getHost(self: *const URL) []const u8 {
    return U.getHost(self._raw);
}

pub fn getPort(self: *const URL) []const u8 {
    return U.getPort(self._raw);
}

pub fn getOrigin(self: *const URL, page: *const Page) ![]const u8 {
    return (try U.getOrigin(page.call_arena, self._raw)) orelse {
        // yes, a null string, that's what the spec wants
        return "null";
    };
}

pub fn getSearch(self: *const URL, page: *const Page) ![]const u8 {
    // If searchParams has been accessed, generate search from it
    if (self._search_params) |sp| {
        if (sp.getSize() == 0) {
            return "";
        }
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try buf.writer.writeByte('?');
        try sp.toString(&buf.writer);
        return buf.written();
    }
    return U.getSearch(self._raw);
}

pub fn getHash(self: *const URL) []const u8 {
    return U.getHash(self._raw);
}

pub fn getSearchParams(self: *URL, page: *Page) !*URLSearchParams {
    if (self._search_params) |sp| {
        return sp;
    }

    // Get current search string (without the '?')
    const search = try self.getSearch(page);
    const search_value = if (search.len > 0) search[1..] else "";

    const params = try URLSearchParams.init(.{ .query_string = search_value }, page);
    self._search_params = params;
    return params;
}

pub fn setHref(self: *URL, value: []const u8, page: *Page) !void {
    const base = if (U.isCompleteHTTPUrl(value)) page.url else self._raw;
    const raw = try U.resolve(self._arena orelse page.arena, base, value, .{ .always_dupe = true });
    self._raw = raw;

    // Update existing searchParams if it exists
    if (self._search_params) |sp| {
        const search = U.getSearch(raw);
        const search_value = if (search.len > 0) search[1..] else "";
        try sp.updateFromString(search_value, page);
    }
}

pub fn setProtocol(self: *URL, value: []const u8) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setProtocol(self._raw, value, allocator);
}

pub fn setHost(self: *URL, value: []const u8) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setHost(self._raw, value, allocator);
}

pub fn setHostname(self: *URL, value: []const u8) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setHostname(self._raw, value, allocator);
}

pub fn setPort(self: *URL, value: ?[]const u8) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setPort(self._raw, value, allocator);
}

pub fn setPathname(self: *URL, value: []const u8) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setPathname(self._raw, value, allocator);
}

pub fn setSearch(self: *URL, value: []const u8, page: *Page) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setSearch(self._raw, value, allocator);

    // Update existing searchParams if it exists
    if (self._search_params) |sp| {
        const search = U.getSearch(self._raw);
        const search_value = if (search.len > 0) search[1..] else "";
        try sp.updateFromString(search_value, page);
    }
}

pub fn setHash(self: *URL, value: []const u8) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setHash(self._raw, value, allocator);
}

pub fn toString(self: *const URL, page: *const Page) ![:0]const u8 {
    const sp = self._search_params orelse {
        return self._raw;
    };

    // Rebuild URL from searchParams
    const raw = self._raw;

    // Find the base (everything before ? or #)
    const base_end = std.mem.indexOfAnyPos(u8, raw, 0, "?#") orelse raw.len;
    const base = raw[0..base_end];

    // Get the hash if it exists
    const hash = self.getHash();

    // Build the new URL string
    var buf = std.Io.Writer.Allocating.init(page.call_arena);
    try buf.writer.writeAll(base);

    // Add / if missing (e.g., "https://example.com" -> "https://example.com/")
    // Only add if pathname is just "/" and not already in the base
    const pathname = U.getPathname(raw);
    if (std.mem.eql(u8, pathname, "/") and !std.mem.endsWith(u8, base, "/")) {
        try buf.writer.writeByte('/');
    }

    // Only add ? if there are params
    if (sp.getSize() > 0) {
        try buf.writer.writeByte('?');
        try sp.toString(&buf.writer);
    }

    try buf.writer.writeAll(hash);
    try buf.writer.writeByte(0);

    return buf.written()[0 .. buf.written().len - 1 :0];
}

pub fn canParse(url: []const u8, base_: ?[]const u8) bool {
    if (base_) |b| {
        return U.isCompleteHTTPUrl(b);
    }
    return U.isCompleteHTTPUrl(url);
}

pub fn createObjectURL(blob: *Blob, page: *Page) ![]const u8 {
    var uuid_buf: [36]u8 = undefined;
    @import("../../id.zig").uuidv4(&uuid_buf);

    const origin = (try page.getOrigin(page.call_arena)) orelse "null";
    const blob_url = try std.fmt.allocPrint(
        page.arena,
        "blob:{s}/{s}",
        .{ origin, uuid_buf },
    );
    try page._blob_urls.put(page.arena, blob_url, blob);
    return blob_url;
}

pub fn revokeObjectURL(url: []const u8, page: *Page) void {
    // Per spec: silently ignore non-blob URLs
    if (!std.mem.startsWith(u8, url, "blob:")) {
        return;
    }

    // Remove from registry (no-op if not found)
    _ = page._blob_urls.remove(url);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(URL);

    pub const Meta = struct {
        pub const name = "URL";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(URL.init, .{});
    pub const canParse = bridge.function(URL.canParse, .{ .static = true });
    pub const createObjectURL = bridge.function(URL.createObjectURL, .{ .static = true });
    pub const revokeObjectURL = bridge.function(URL.revokeObjectURL, .{ .static = true });
    pub const toString = bridge.function(URL.toString, .{});
    pub const toJSON = bridge.function(URL.toString, .{});
    pub const href = bridge.accessor(URL.toString, URL.setHref, .{});
    pub const search = bridge.accessor(URL.getSearch, URL.setSearch, .{});
    pub const hash = bridge.accessor(URL.getHash, URL.setHash, .{});
    pub const pathname = bridge.accessor(URL.getPathname, URL.setPathname, .{});
    pub const username = bridge.accessor(URL.getUsername, null, .{});
    pub const password = bridge.accessor(URL.getPassword, null, .{});
    pub const hostname = bridge.accessor(URL.getHostname, URL.setHostname, .{});
    pub const host = bridge.accessor(URL.getHost, URL.setHost, .{});
    pub const port = bridge.accessor(URL.getPort, URL.setPort, .{});
    pub const origin = bridge.accessor(URL.getOrigin, null, .{});
    pub const protocol = bridge.accessor(URL.getProtocol, URL.setProtocol, .{});
    pub const searchParams = bridge.accessor(URL.getSearchParams, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: URL" {
    try testing.htmlRunner("url.html", .{});
}
