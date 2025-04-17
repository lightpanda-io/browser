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
const SessionState = @import("../env.zig").SessionState;

const query = @import("query.zig");

pub const Interfaces = .{
    URL,
    URLSearchParams,
};

// https://url.spec.whatwg.org/#url
//
// TODO we could avoid many of these getter string allocatoration in two differents
// way:
//
// 1. We can eventually get the slice of scheme *with* the following char in
// the underlying string. But I don't know if it's possible and how to do that.
// I mean, if the rawuri contains `https://foo.bar`, uri.scheme is a slice
// containing only `https`. I want `https:` so, in theory, I don't need to
// allocatorate data, I should be able to retrieve the scheme + the following `:`
// from rawuri.
//
// 2. The other way would bu to copy the `std.Uri` code to ahve a dedicated
// parser including the characters we want for the web API.
pub const URL = struct {
    uri: std.Uri,
    search_params: URLSearchParams,

    pub fn constructor(
        url: []const u8,
        base: ?[]const u8,
        state: *SessionState,
    ) !URL {
        const arena = state.arena;
        const raw = try std.mem.concat(arena, u8, &[_][]const u8{ url, base orelse "" });
        errdefer arena.free(raw);

        const uri = std.Uri.parse(raw) catch return error.TypeError;
        return init(arena, uri);
    }

    pub fn init(arena: std.mem.Allocator, uri: std.Uri) !URL {
        return .{
            .uri = uri,
            .search_params = try URLSearchParams.init(
                arena,
                uriComponentNullStr(uri.query),
            ),
        };
    }

    pub fn get_origin(self: *URL, state: *SessionState) ![]const u8 {
        var buf = std.ArrayList(u8).init(state.arena);
        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = false,
            .authority = true,
            .path = false,
            .query = false,
            .fragment = false,
        }, buf.writer());
        return buf.items;
    }

    // get_href returns the URL by writing all its components.
    // The query is replaced by a dump of search params.
    //
    pub fn get_href(self: *URL, state: *SessionState) ![]const u8 {
        const arena = state.arena;
        // retrieve the query search from search_params.
        const cur = self.uri.query;
        defer self.uri.query = cur;
        var q = std.ArrayList(u8).init(arena);
        try self.search_params.values.encode(q.writer());
        self.uri.query = .{ .percent_encoded = q.items };

        return try self.toString(arena);
    }

    // format the url with all its components.
    pub fn toString(self: *URL, arena: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(arena);

        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = true,
            .authority = true,
            .path = uriComponentNullStr(self.uri.path).len > 0,
            .query = uriComponentNullStr(self.uri.query).len > 0,
            .fragment = uriComponentNullStr(self.uri.fragment).len > 0,
        }, buf.writer());
        return buf.items;
    }

    pub fn get_protocol(self: *URL, state: *SessionState) ![]const u8 {
        return try std.mem.concat(state.arena, u8, &[_][]const u8{ self.uri.scheme, ":" });
    }

    pub fn get_username(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.user);
    }

    pub fn get_password(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.password);
    }

    pub fn get_host(self: *URL, state: *SessionState) ![]const u8 {
        var buf = std.ArrayList(u8).init(state.arena);

        try self.uri.writeToStream(.{
            .scheme = false,
            .authentication = false,
            .authority = true,
            .path = false,
            .query = false,
            .fragment = false,
        }, buf.writer());
        return buf.items;
    }

    pub fn get_hostname(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.host);
    }

    pub fn get_port(self: *URL, state: *SessionState) ![]const u8 {
        const arena = state.arena;
        if (self.uri.port == null) return try arena.dupe(u8, "");

        var buf = std.ArrayList(u8).init(arena);
        try std.fmt.formatInt(self.uri.port.?, 10, .lower, .{}, buf.writer());
        return buf.items;
    }

    pub fn get_pathname(self: *URL) []const u8 {
        if (uriComponentStr(self.uri.path).len == 0) return "/";
        return uriComponentStr(self.uri.path);
    }

    pub fn get_search(self: *URL, state: *SessionState) ![]const u8 {
        const arena = state.arena;
        if (self.search_params.get_size() == 0) return try arena.dupe(u8, "");

        var buf: std.ArrayListUnmanaged(u8) = .{};

        try buf.append(arena, '?');
        try self.search_params.values.encode(buf.writer(arena));
        return buf.items;
    }

    pub fn get_hash(self: *URL, state: *SessionState) ![]const u8 {
        const arena = state.arena;
        if (self.uri.fragment == null) return try arena.dupe(u8, "");

        return try std.mem.concat(arena, u8, &[_][]const u8{ "#", uriComponentNullStr(self.uri.fragment) });
    }

    pub fn get_searchParams(self: *URL) *URLSearchParams {
        return &self.search_params;
    }

    pub fn _toJSON(self: *URL, state: *SessionState) ![]const u8 {
        return try self.get_href(state);
    }
};

// uriComponentNullStr converts an optional std.Uri.Component to string value.
// The string value can be undecoded.
fn uriComponentNullStr(c: ?std.Uri.Component) []const u8 {
    if (c == null) return "";

    return uriComponentStr(c.?);
}

fn uriComponentStr(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
}

// https://url.spec.whatwg.org/#interface-urlsearchparams
// TODO array like
pub const URLSearchParams = struct {
    values: query.Values,

    pub fn constructor(qs: ?[]const u8, state: *SessionState) !URLSearchParams {
        return init(state.arena, qs);
    }

    pub fn init(arena: std.mem.Allocator, qs: ?[]const u8) !URLSearchParams {
        return .{
            .values = try query.parseQuery(arena, qs orelse ""),
        };
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

const testing = @import("../../testing.zig");
test "Browser.URL" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "var url = new URL('https://foo.bar/path?query#fragment')", "undefined" },
        .{ "url.origin", "https://foo.bar" },
        .{ "url.href", "https://foo.bar/path?query#fragment" },
        .{ "url.protocol", "https:" },
        .{ "url.username", "" },
        .{ "url.password", "" },
        .{ "url.host", "foo.bar" },
        .{ "url.hostname", "foo.bar" },
        .{ "url.port", "" },
        .{ "url.pathname", "/path" },
        .{ "url.search", "?query" },
        .{ "url.hash", "#fragment" },
        .{ "url.searchParams.get('query')", "" },
    }, .{});

    try runner.testCases(&.{
        .{ "var url = new URL('https://foo.bar/path?a=~&b=%7E#fragment')", "undefined" },
        .{ "url.searchParams.get('a')", "~" },
        .{ "url.searchParams.get('b')", "~" },
        .{ "url.searchParams.append('c', 'foo')", "undefined" },
        .{ "url.searchParams.get('c')", "foo" },
        .{ "url.searchParams.size", "3" },

        // search is dynamic
        .{ "url.search", "?a=%7E&b=%7E&c=foo" },
        // href is dynamic
        .{ "url.href", "https://foo.bar/path?a=%7E&b=%7E&c=foo#fragment" },

        .{ "url.searchParams.delete('c', 'foo')", "undefined" },
        .{ "url.searchParams.get('c')", "" },
        .{ "url.searchParams.delete('a')", "undefined" },
        .{ "url.searchParams.get('a')", "" },
    }, .{});
}
