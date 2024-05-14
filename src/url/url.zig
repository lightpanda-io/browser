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

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const query = @import("query.zig");

pub const Interfaces = generate.Tuple(.{
    URL,
    URLSearchParams,
});

// https://url.spec.whatwg.org/#url
//
// TODO we could avoid many of these getter string allocation in two differents
// way:
//
// 1. We can eventually get the slice of scheme *with* the following char in
// the underlying string. But I don't know if it's possible and how to do that.
// I mean, if the rawuri contains `https://foo.bar`, uri.scheme is a slice
// containing only `https`. I want `https:` so, in theory, I don't need to
// allocate data, I should be able to retrieve the scheme + the following `:`
// from rawuri.
//
// 2. The other way would bu to copy the `std.Uri` code to ahve a dedicated
// parser including the characters we want for the web API.
pub const URL = struct {
    rawuri: []const u8,
    uri: std.Uri,
    search_params: URLSearchParams,

    pub const mem_guarantied = true;

    pub fn constructor(alloc: std.mem.Allocator, url: []const u8, base: ?[]const u8) !URL {
        const raw = try std.mem.concat(alloc, u8, &[_][]const u8{ url, base orelse "" });
        errdefer alloc.free(raw);

        const uri = std.Uri.parse(raw) catch {
            return error.TypeError;
        };

        return .{
            .rawuri = raw,
            .uri = uri,
            .search_params = try URLSearchParams.constructor(alloc, uri.query),
        };
    }

    pub fn deinit(self: *URL, alloc: std.mem.Allocator) void {
        self.search_params.deinit();
        alloc.free(self.rawuri);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_href(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        // retrieve the query search from search_params.
        const cur = self.uri.query;
        defer self.uri.query = cur;
        var q = std.ArrayList(u8).init(alloc);
        defer q.deinit();
        try self.search_params.values.encode(q.writer());
        self.uri.query = q.items;

        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = true,
            .authority = true,
            .path = true,
            .query = true,
            .fragment = true,
        }, buf.writer());
        return try buf.toOwnedSlice();
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_protocol(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        return try std.mem.concat(alloc, u8, &[_][]const u8{ self.uri.scheme, ":" });
    }

    pub fn get_username(self: *URL) []const u8 {
        return self.uri.user orelse "";
    }

    pub fn get_password(self: *URL) []const u8 {
        return self.uri.password orelse "";
    }

    pub fn get_host(self: *URL) []const u8 {
        return self.uri.host orelse "";
    }

    pub fn get_hostname(self: *URL) []const u8 {
        return self.uri.host orelse "";
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_port(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.uri.port == null) return try alloc.dupe(u8, "");

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        try std.fmt.formatInt(self.uri.port.?, 10, .lower, .{}, buf.writer());
        return try buf.toOwnedSlice();
    }

    pub fn get_pathname(self: *URL) []const u8 {
        if (self.uri.path.len == 0) return "/";
        return self.uri.path;
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_search(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.search_params.get_size() == 0) return try alloc.dupe(u8, "");

        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(alloc);

        try buf.append(alloc, '?');
        try self.search_params.values.encode(buf.writer(alloc));
        return buf.toOwnedSlice(alloc);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_hash(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.uri.fragment == null) return try alloc.dupe(u8, "");

        return try std.mem.concat(alloc, u8, &[_][]const u8{ "#", self.uri.fragment.? });
    }

    pub fn get_searchParams(self: *URL) *URLSearchParams {
        return &self.search_params;
    }

    pub fn _toJSON(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        return try self.get_href(alloc);
    }
};

// https://url.spec.whatwg.org/#interface-urlsearchparams
// TODO array like
pub const URLSearchParams = struct {
    values: query.Values,

    pub const mem_guarantied = true;

    pub fn constructor(alloc: std.mem.Allocator, init: ?[]const u8) !URLSearchParams {
        return .{
            .values = try query.parseQuery(alloc, init orelse ""),
        };
    }

    pub fn deinit(self: *URLSearchParams, _: std.mem.Allocator) void {
        self.values.deinit();
    }

    pub fn get_size(self: *URLSearchParams) u32 {
        return @intCast(self.values.count());
    }

    pub fn _append(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
        try self.values.append(name, value);
    }

    pub fn _delete(self: *URLSearchParams, name: []const u8, value: ?[]const u8) !void {
        if (value) |v| return self.values.deleteValue(name, v);

        self.values.delete(name);
    }

    pub fn _get(self: *URLSearchParams, name: []const u8) ?[]const u8 {
        return self.values.first(name);
    }

    // TODO return generates an error: caught unexpected error 'TypeLookup'
    // pub fn _getAll(self: *URLSearchParams, name: []const u8) [][]const u8 {
    //     try self.values.get(name);
    // }

    // TODO
    pub fn _sort(_: *URLSearchParams) void {}
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var url = [_]Case{
        .{ .src = "var url = new URL('https://foo.bar/path?query#fragment')", .ex = "undefined" },
        .{ .src = "url.href", .ex = "https://foo.bar/path?query#fragment" },
        .{ .src = "url.protocol", .ex = "https:" },
        .{ .src = "url.username", .ex = "" },
        .{ .src = "url.password", .ex = "" },
        .{ .src = "url.host", .ex = "foo.bar" },
        .{ .src = "url.hostname", .ex = "foo.bar" },
        .{ .src = "url.port", .ex = "" },
        .{ .src = "url.pathname", .ex = "/path" },
        .{ .src = "url.search", .ex = "?query" },
        .{ .src = "url.hash", .ex = "#fragment" },
        .{ .src = "url.searchParams.get('query')", .ex = "" },
    };
    try checkCases(js_env, &url);

    var qs = [_]Case{
        .{ .src = "var url = new URL('https://foo.bar/path?a=~&b=%7E#fragment')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('a')", .ex = "~" },
        .{ .src = "url.searchParams.get('b')", .ex = "~" },
        .{ .src = "url.searchParams.append('c', 'foo')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('c')", .ex = "foo" },
        .{ .src = "url.searchParams.size", .ex = "3" },

        // search is dynamic
        .{ .src = "url.search", .ex = "?a=%7E&b=%7E&c=foo" },
        // href is dynamic
        .{ .src = "url.href", .ex = "https://foo.bar/path?a=%7E&b=%7E&c=foo#fragment" },

        .{ .src = "url.searchParams.delete('c', 'foo')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('c')", .ex = "" },
        .{ .src = "url.searchParams.delete('a')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('a')", .ex = "" },
    };
    try checkCases(js_env, &qs);
}
