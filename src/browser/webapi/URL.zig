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
const U_ = @import("../../sys/url.zig");
const URLSearchParams = @import("net/URLSearchParams.zig");
const Blob = @import("Blob.zig");
const Execution = js.Execution;

const Allocator = std.mem.Allocator;

const URL = @This();

_raw: [:0]const u8 = undefined,
_url: *U_.Url = undefined,
/// Largest port possible is 65535; which require 5 bytes.
_port: [5]u8 = undefined,
_arena: ?Allocator = null,
_search_params: ?*URLSearchParams = null,

// convenience
pub const resolve = @import("../URL.zig").resolve;
pub const eqlDocument = @import("../URL.zig").eqlDocument;

pub fn init(url: []const u8, maybe_base: ?[]const u8, exec: *const Execution) !*URL {
    // NOTE: about:blank address is valid in rust-url.

    var err: i32 = 0;
    if (maybe_base) |base| {
        const base_url = U_.url_parse(base.ptr, base.len, &err) orelse return error.TypeError;
        errdefer U_.url_free(base_url);

        const joined_url = U_.url_join(base_url, url.ptr, url.len, &err) orelse return error.TypeError;
        errdefer U_.url_free(joined_url);
        // `base_url` has no use now.
        U_.url_free(base_url);

        return exec._factory.create(URL{ ._url = joined_url });
    }

    const u = U_.url_parse(url.ptr, url.len, &err) orelse {
        return error.TypeError;
    };
    errdefer U_.url_free(u);

    return exec._factory.create(URL{ ._url = u });
}

pub fn getUsername(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U_.url_get_username(self._url, &out, &len);
    return out[0..len];
}

pub fn setUsername(self: *URL, value: []const u8) !void {
    const res = U_.url_set_username(self._url, value.ptr, value.len);
    if (res != 0) {
        return error.SetUsername;
    }
}

pub fn getPassword(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const res = U_.url_get_password(self._url, &out, &len);
    if (res != 0) {
        return "";
    }
    return out[0..len];
}

pub fn setPassword(self: *URL, value: []const u8) !void {
    const res = U_.url_set_password(self._url, value.ptr, value.len);
    if (res != 0) {
        return error.SetPassword;
    }
}

pub fn getPathname(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U_.url_get_path(self._url, &out, &len);
    return out[0..len];
}

pub fn setPathname(self: *URL, value: []const u8) !void {
    const res = U_.url_set_path(self._url, value.ptr, value.len);
    if (res != 0) {
        return error.SetPathname;
    }
}

pub fn getProtocol(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U_.url_get_scheme(self._url, &out, &len);
    // rust-url's scheme() omits the ':'. The serialization always has it right
    // after the scheme ("https://..."), so we extend the borrowed slice by one.
    return out[0 .. len + 1];
}

pub fn setProtocol(self: *URL, value: []const u8) !void {
    const res = U_.url_set_scheme(self._url, value.ptr, value.len);
    if (res != 0) {
        return error.SetProtocol;
    }
}

pub fn getHostname(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U_.url_get_hostname(self._url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

pub fn setHostname(self: *URL, value: []const u8) !void {
    const res = U_.url_set_hostname(self._url, value.ptr, value.len);
    if (res != 0) {
        return error.SetHostname;
    }
}

pub fn getHost(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U_.url_get_host(self._url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

pub fn setHost(self: *URL, value: []const u8) !void {
    const res = U_.url_set_host(self._url, value.ptr, value.len);
    if (res != 0) {
        return error.SetHost;
    }
}

pub fn getPort(self: *URL) []const u8 {
    const port = U_.urlGetPort(self._url) orelse return "";
    return std.fmt.bufPrint(&self._port, "{d}", .{port}) catch unreachable;
}

/// Spec requires us to silently ignore errors of this setter.
pub fn setPort(self: *URL, maybe_value: ?[]const u8) void {
    // A null or empty value clears the port.
    const value = maybe_value orelse {
        _ = U_.url_set_port_to_null(self._url);
        return;
    };
    if (value.len == 0) {
        _ = U_.url_set_port_to_null(self._url);
        return;
    }

    // Ignore invalid port numbers, leaving the port unchanged.
    const port = std.fmt.parseInt(u16, value, 10) catch return;
    _ = U_.url_set_port(self._url, port);
}

pub fn getSearch(self: *const URL, exec: *const Execution) ![]const u8 {
    // If searchParams has been accessed, generate search from it
    if (self._search_params) |sp| {
        if (sp.getSize() == 0) {
            return "";
        }
        var buf = std.Io.Writer.Allocating.init(exec.call_arena);
        try buf.writer.writeByte('?');
        try sp.toString(&buf.writer);
        return buf.written();
    }
    return U.getSearch(self._raw);
}

pub fn setSearch(self: *URL, value: []const u8, exec: *const Execution) !void {
    const allocator = self._arena orelse return error.NoAllocator;
    self._raw = try U.setSearch(self._raw, value, allocator);

    // Update existing searchParams if it exists
    if (self._search_params) |sp| {
        const search = U.getSearch(self._raw);
        const search_value = if (search.len > 0) search[1..] else "";
        try sp.updateFromString(search_value, exec);
    }
}

pub fn getHash(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const res = U_.url_get_fragment(self._url, &out, &len);
    // WHATWG `hash` is "" for both a null and an empty fragment.
    if (res != 0 or len == 0) {
        return "";
    }
    // rust-url's fragment() omits the '#', which always precedes the fragment
    // in the serialization, so step the borrowed slice back one byte for it.
    return (out - 1)[0 .. len + 1];
}

pub fn setHash(self: *URL, value: []const u8) !void {
    // An empty value clears the fragment entirely (removes the '#').
    if (value.len == 0) {
        U_.url_set_fragment_to_null(self._url);
        return;
    }
    // Strip a single leading '#', then set the fragment.
    const fragment = if (value[0] == '#') value[1..] else value;
    const res = U_.url_set_fragment(self._url, fragment.ptr, fragment.len);
    if (res != 0) {
        return error.SetHash;
    }
}

pub fn getSearchParams(self: *URL, exec: *const Execution) !*URLSearchParams {
    if (self._search_params) |sp| {
        return sp;
    }

    // Get current search string (without the '?')
    const search = try self.getSearch(exec);
    const search_value = if (search.len > 0) search[1..] else "";

    const params = try URLSearchParams.init(.{ .query_string = search_value }, exec);
    self._search_params = params;
    return params;
}

pub fn getOrigin(self: *const URL, exec: *const Execution) ![]const u8 {
    const origin = U_.url_get_origin(self._url);
    defer origin.deinit();

    return exec.call_arena.dupe(u8, origin.slice());
}

pub fn setHref(self: *URL, value: []const u8, exec: *const Execution) !void {
    // This behaves the same as initializing a URL.
    var err: i32 = 0;
    const url = U_.url_parse(value.ptr, value.len, &err) orelse return error.TypeError;
    errdefer U_.url_free(url);

    // Free the current URL.
    U_.url_free(self._url);
    self._url = url;

    // Update existing searchParams if it exists.
    if (self._search_params) |sp| {
        const search = U.getSearch(self.toString());
        const search_value = if (search.len > 0) search[1..] else "";
        try sp.updateFromString(search_value, exec);
    }
}

pub fn toString(self: *const URL) []const u8 {
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    U_.url_to_string(self._url, &ptr, &len);
    return ptr[0..len];
}

pub fn toString1(self: *const URL, exec: *const Execution) ![:0]const u8 {
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
    var buf = std.Io.Writer.Allocating.init(exec.call_arena);
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

pub fn canParse(url: []const u8, maybe_base: ?[]const u8) bool {
    if (maybe_base) |base| {
        return U_.url_can_parse_with_base(base.ptr, base.len, url.ptr, url.len);
    }
    return U_.url_can_parse(url.ptr, url.len);
}

pub fn createObjectURL(blob: *Blob, exec: *const Execution) ![]const u8 {
    var uuid_buf: [36]u8 = undefined;
    @import("../../id.zig").uuidv4(&uuid_buf);

    switch (exec.js.global) {
        inline else => |g| {
            const blob_url = try std.fmt.allocPrint(
                g.arena,
                "blob:{s}/{s}",
                .{ g.origin orelse "null", uuid_buf },
            );
            try g._blob_urls.put(g.arena, blob_url, blob);
            blob.acquireRef();
            return blob_url;
        },
    }
}

pub fn revokeObjectURL(url: []const u8, exec: *const Execution) void {
    // Per spec: silently ignore non-blob URLs
    if (!std.mem.startsWith(u8, url, "blob:")) {
        return;
    }

    switch (exec.js.global) {
        inline else => |g| {
            if (g._blob_urls.fetchRemove(url)) |entry| {
                entry.value.releaseRef(g._page);
            }
        },
    }
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
    pub const username = bridge.accessor(URL.getUsername, URL.setUsername, .{});
    pub const password = bridge.accessor(URL.getPassword, URL.setPassword, .{});
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
