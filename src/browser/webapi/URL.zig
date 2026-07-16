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
const lp = @import("lightpanda");
const js = @import("../js/js.zig");

const U = @import("../../sys/url.zig");
const Page = @import("../Page.zig");
const URLSearchParams = @import("net/URLSearchParams.zig");
const Blob = @import("Blob.zig");
const Execution = js.Execution;

const URL = @This();

_url: *U.Url = undefined,
/// Largest port possible is 65535; which require 5 bytes.
_port: [5]u8 = undefined,
_search_params: ?*URLSearchParams = null,
/// We have to track lifetime of URL to free `_url`.
_rc: lp.RC(u32) = .{},

// convenience
pub const resolve = @import("../URL.zig").resolve;
pub const eqlDocument = @import("../URL.zig").eqlDocument;

pub fn init(url: []const u8, maybe_base: ?[]const u8, exec: *const Execution) !*URL {
    // NOTE: about:blank address is valid in rust-url.
    var err: i32 = 0;
    const u = blk: {
        if (maybe_base) |base| {
            break :blk U.url_parse_with_base(base.ptr, base.len, url.ptr, url.len, &err) orelse return error.TypeError;
        }
        break :blk U.url_parse(url.ptr, url.len, &err) orelse return error.TypeError;
    };
    errdefer U.url_free(u);

    return exec._factory.create(URL{ ._url = u });
}

/// Like the constructor, but returns null instead of throwing when parsing fails.
pub fn parse(url: []const u8, maybe_base: ?[]const u8, exec: *const Execution) ?*URL {
    return URL.init(url, maybe_base, exec) catch null;
}

pub fn deinit(self: *URL, page: *Page) void {
    if (self._search_params) |search_params| {
        search_params.releaseRef(page);
    }
    // Not tracked by arena.
    U.url_free(self._url);
}

pub fn acquireRef(self: *URL) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *URL, page: *Page) void {
    self._rc.release(self, page);
}

pub fn getUsername(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U.url_get_username(self._url, &out, &len);
    return out[0..len];
}

pub fn setUsername(self: *URL, value: []const u8) void {
    _ = U.url_set_username(self._url, value.ptr, value.len);
}

pub fn getPassword(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const res = U.url_get_password(self._url, &out, &len);
    if (res != 0) {
        return "";
    }
    return out[0..len];
}

pub fn setPassword(self: *URL, value: []const u8) void {
    _ = U.url_set_password(self._url, value.ptr, value.len);
}

pub fn getPathname(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U.url_get_path(self._url, &out, &len);
    return out[0..len];
}

pub fn setPathname(self: *URL, value: []const u8) void {
    _ = U.url_set_path(self._url, value.ptr, value.len);
}

pub fn getProtocol(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U.url_get_scheme(self._url, &out, &len);
    // rust-url's scheme() omits the ':'. The serialization always has it right
    // after the scheme ("https://..."), so we extend the borrowed slice by one.
    return out[0 .. len + 1];
}

pub fn setProtocol(self: *URL, value: []const u8) void {
    _ = U.url_set_scheme(self._url, value.ptr, value.len);
}

pub fn getHostname(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U.url_get_hostname(self._url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

pub fn setHostname(self: *URL, value: []const u8) void {
    _ = U.url_set_hostname(self._url, value.ptr, value.len);
}

pub fn getHost(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U.url_get_host(self._url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

pub fn setHost(self: *URL, value: []const u8) void {
    _ = U.url_set_host(self._url, value.ptr, value.len);
}

pub fn getPort(self: *URL) []const u8 {
    const port = U.urlGetPort(self._url) orelse return "";
    return std.fmt.bufPrint(&self._port, "{d}", .{port}) catch unreachable;
}

/// Spec requires us to silently ignore errors of this setter.
pub fn setPort(self: *URL, maybe_value: ?[]const u8) void {
    // A null or empty value clears the port.
    const value = maybe_value orelse {
        _ = U.url_set_port_to_null(self._url);
        return;
    };
    if (value.len == 0) {
        _ = U.url_set_port_to_null(self._url);
        return;
    }

    // Ignore invalid port numbers, leaving the port unchanged.
    const port = std.fmt.parseInt(u16, value, 10) catch return;
    _ = U.url_set_port(self._url, port);
}

pub fn getSearch(self: *const URL, exec: *const Execution) ![]const u8 {
    if (self._search_params) |search_params| {
        if (search_params.getSize() == 0) {
            return "";
        }

        var buf = std.Io.Writer.Allocating.init(exec.local_arena);
        try buf.writer.writeByte('?');
        try search_params.toString(&buf.writer);
        return buf.written();
    }

    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const res = U.url_get_query(self._url, &out, &len);
    if (res != 0 or len == 0) {
        return "";
    }

    // rust-url's query() omits the '?', which always precedes the query.
    return (out - 1)[0 .. len + 1];
}

pub fn setSearch(self: *URL, value: []const u8, exec: *const Execution) !void {
    // Empty value clears the query entirely.
    if (value.len == 0) {
        // Reset searchParams.
        if (self._search_params) |search_params| {
            search_params._params = .empty;
        }

        U.url_set_query_to_null(self._url);
        return;
    }

    // Strip a single leading '?', then set the query.
    const query = if (value[0] == '?') value[1..] else value;

    if (U.url_set_query(self._url, query.ptr, query.len) != 0) {
        return;
    }

    // If searchParams exists, update it too.
    const search_params = self._search_params orelse return;
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const search_value = if (U.url_get_query(self._url, &out, &len) == 0) (out - 1)[0 .. len + 1] else "";
    try search_params.updateFromString(search_value, exec);
}

pub fn getHash(self: *const URL) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const res = U.url_get_fragment(self._url, &out, &len);
    // WHATWG `hash` is "" for both a null and an empty fragment.
    if (res != 0 or len == 0) {
        return "";
    }
    // rust-url's fragment() omits the '#', which always precedes the fragment
    // in the serialization, so step the borrowed slice back one byte for it.
    return (out - 1)[0 .. len + 1];
}

pub fn setHash(self: *URL, value: []const u8) void {
    // An empty value clears the fragment entirely (removes the '#').
    if (value.len == 0) {
        U.url_set_fragment_to_null(self._url);
        return;
    }
    // Strip a single leading '#', then set the fragment.
    const fragment = if (value[0] == '#') value[1..] else value;
    _ = U.url_set_fragment(self._url, fragment.ptr, fragment.len);
}

pub fn getSearchParams(self: *URL, exec: *const Execution) !*URLSearchParams {
    if (self._search_params) |sp| {
        return sp;
    }

    // Get current search string; rust-url always skips '?' so we have to
    // go a byte back to include it.
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const search_value = if (U.url_get_query(self._url, &out, &len) == 0) (out - 1)[0 .. len + 1] else "";

    const params = try URLSearchParams.init(.{ .query_string = search_value }, exec);
    // Released in deinit; the cached params must outlive their JS wrapper.
    params.acquireRef();
    self._search_params = params;
    return params;
}

pub fn getOrigin(self: *const URL, exec: *const Execution) ![]const u8 {
    const origin = U.url_get_origin(self._url);
    defer origin.deinit();

    return exec.local_arena.dupe(u8, origin.slice());
}

pub fn setHref(self: *URL, value: []const u8, exec: *const Execution) !void {
    // Parse first: a failed href setter must leave the URL unchanged (and we
    // must not free self._url before we know we have a replacement, or any
    // later access would be a use-after-free).
    var err: i32 = 0;
    const url = U.url_parse(value.ptr, value.len, &err) orelse return error.TypeError;

    U.url_free(self._url);
    self._url = url;

    // Update existing searchParams if exists.
    const search_params = self._search_params orelse return;
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    const search_value = if (U.url_get_query(url, &out, &len) == 0) (out - 1)[0 .. len + 1] else "";
    try search_params.updateFromString(search_value, exec);
}

pub fn toString(self: *const URL, exec: *const Execution) ![]const u8 {
    if (self._search_params) |search_params| {
        if (search_params.getSize() == 0) {
            U.url_set_query_to_null(self._url);
        } else {
            var buf = std.Io.Writer.Allocating.init(exec.local_arena);
            defer buf.deinit();
            try search_params.toString(&buf.writer);
            const query = buf.written();
            if (U.url_set_query(self._url, query.ptr, query.len) != 0) {
                return error.ToString;
            }
        }
    }

    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U.url_to_string(self._url, &out, &len);
    return out[0..len];
}

pub fn canParse(url: []const u8, maybe_base: ?[]const u8) bool {
    if (maybe_base) |base| {
        return U.url_can_parse_with_base(base.ptr, base.len, url.ptr, url.len);
    }
    return U.url_can_parse(url.ptr, url.len);
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
    pub const parse = bridge.function(URL.parse, .{ .static = true });
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
