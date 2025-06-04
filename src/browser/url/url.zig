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
const Allocator = std.mem.Allocator;

const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;
const FormData = @import("../xhr/form_data.zig").FormData;
const HTMLElement = @import("../html/elements.zig").HTMLElement;

const kv = @import("../key_value.zig");
const iterator = @import("../iterator/iterator.zig");

pub const Interfaces = .{
    URL,
    URLSearchParams,
    KeyIterable,
    ValueIterable,
    EntryIterable,
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

    const URLArg = union(enum) {
        url: *URL,
        element: *parser.ElementHTML,
        string: []const u8,

        fn toString(self: URLArg, arena: Allocator) !?[]const u8 {
            switch (self) {
                .string => |s| return s,
                .url => |url| return try url.toString(arena),
                .element => |e| return try parser.elementGetAttribute(@ptrCast(e), "href"),
            }
        }
    };

    pub fn constructor(url: URLArg, base: ?URLArg, page: *Page) !URL {
        const arena = page.arena;
        const url_str = try url.toString(arena) orelse return error.InvalidArgument;

        var raw: ?[]const u8 = null;
        if (base) |b| {
            if (try b.toString(arena)) |bb| {
                raw = try @import("../../url.zig").URL.stitch(arena, url_str, bb, .{});
            }
        }

        if (raw == null) {
            // if it was a URL, then it's already be owned by the arena
            raw = if (url == .url) url_str else try arena.dupe(u8, url_str);
        }

        const uri = std.Uri.parse(raw.?) catch return error.TypeError;
        return init(arena, uri);
    }

    pub fn init(arena: Allocator, uri: std.Uri) !URL {
        return .{
            .uri = uri,
            .search_params = try URLSearchParams.init(
                arena,
                uriComponentNullStr(uri.query),
            ),
        };
    }

    pub fn get_origin(self: *URL, page: *Page) ![]const u8 {
        var buf = std.ArrayList(u8).init(page.arena);
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
    pub fn get_href(self: *URL, page: *Page) ![]const u8 {
        return try self.toString(page.arena);
    }

    // format the url with all its components.
    pub fn toString(self: *const URL, arena: Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = true,
            .authority = true,
            .path = uriComponentNullStr(self.uri.path).len > 0,
        }, buf.writer(arena));

        if (self.search_params.get_size() > 0) {
            try buf.append(arena, '?');
            try self.search_params.write(buf.writer(arena));
        }

        {
            const fragment = uriComponentNullStr(self.uri.fragment);
            if (fragment.len > 0) {
                try buf.append(arena, '#');
                try buf.appendSlice(arena, fragment);
            }
        }

        return buf.items;
    }

    pub fn get_protocol(self: *URL, page: *Page) ![]const u8 {
        return try std.mem.concat(page.arena, u8, &[_][]const u8{ self.uri.scheme, ":" });
    }

    pub fn get_username(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.user);
    }

    pub fn get_password(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.password);
    }

    pub fn get_host(self: *URL, page: *Page) ![]const u8 {
        var buf = std.ArrayList(u8).init(page.arena);

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

    pub fn get_port(self: *URL, page: *Page) ![]const u8 {
        const arena = page.arena;
        if (self.uri.port == null) return try arena.dupe(u8, "");

        var buf = std.ArrayList(u8).init(arena);
        try std.fmt.formatInt(self.uri.port.?, 10, .lower, .{}, buf.writer());
        return buf.items;
    }

    pub fn get_pathname(self: *URL) []const u8 {
        if (uriComponentStr(self.uri.path).len == 0) return "/";
        return uriComponentStr(self.uri.path);
    }

    pub fn get_search(self: *URL, page: *Page) ![]const u8 {
        const arena = page.arena;

        if (self.search_params.get_size() == 0) {
            return "";
        }

        var buf: std.ArrayListUnmanaged(u8) = .{};
        try buf.append(arena, '?');
        try self.search_params.encode(buf.writer(arena));
        return buf.items;
    }

    pub fn set_search(self: *URL, qs_: ?[]const u8, page: *Page) !void {
        self.search_params = .{};
        if (qs_) |qs| {
            self.search_params = try URLSearchParams.init(page.arena, qs);
        }
    }

    pub fn get_hash(self: *URL, page: *Page) ![]const u8 {
        const arena = page.arena;
        if (self.uri.fragment == null) return try arena.dupe(u8, "");

        return try std.mem.concat(arena, u8, &[_][]const u8{ "#", uriComponentNullStr(self.uri.fragment) });
    }

    pub fn get_searchParams(self: *URL) *URLSearchParams {
        return &self.search_params;
    }

    pub fn _toJSON(self: *URL, page: *Page) ![]const u8 {
        return self.get_href(page);
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
pub const URLSearchParams = struct {
    entries: kv.List = .{},

    const URLSearchParamsOpts = union(enum) {
        qs: []const u8,
        form_data: *const FormData,
    };
    pub fn constructor(opts_: ?URLSearchParamsOpts, page: *Page) !URLSearchParams {
        const opts = opts_ orelse return .{ .entries = .{} };
        return switch (opts) {
            .qs => |qs| init(page.arena, qs),
            .form_data => |fd| .{ .entries = try fd.entries.clone(page.arena) },
        };
    }

    pub fn init(arena: Allocator, qs_: ?[]const u8) !URLSearchParams {
        return .{
            .entries = if (qs_) |qs| try parseQuery(arena, qs) else .{},
        };
    }

    pub fn get_size(self: *const URLSearchParams) u32 {
        return @intCast(self.entries.count());
    }

    pub fn _append(self: *URLSearchParams, name: []const u8, value: []const u8, page: *Page) !void {
        return self.entries.append(page.arena, name, value);
    }

    pub fn _set(self: *URLSearchParams, name: []const u8, value: []const u8, page: *Page) !void {
        return self.entries.set(page.arena, name, value);
    }

    pub fn _delete(self: *URLSearchParams, name: []const u8, value_: ?[]const u8) void {
        if (value_) |value| {
            return self.entries.deleteKeyValue(name, value);
        }
        return self.entries.delete(name);
    }

    pub fn _get(self: *const URLSearchParams, name: []const u8) ?[]const u8 {
        return self.entries.get(name);
    }

    pub fn _getAll(self: *const URLSearchParams, name: []const u8, page: *Page) ![]const []const u8 {
        return self.entries.getAll(page.call_arena, name);
    }

    pub fn _has(self: *const URLSearchParams, name: []const u8) bool {
        return self.entries.has(name);
    }

    pub fn _keys(self: *const URLSearchParams) KeyIterable {
        return .{ .inner = self.entries.keyIterator() };
    }

    pub fn _values(self: *const URLSearchParams) ValueIterable {
        return .{ .inner = self.entries.valueIterator() };
    }

    pub fn _entries(self: *const URLSearchParams) EntryIterable {
        return .{ .inner = self.entries.entryIterator() };
    }

    pub fn _symbol_iterator(self: *const URLSearchParams) EntryIterable {
        return self._entries();
    }

    fn _toString(self: *const URLSearchParams, page: *Page) ![]const u8 {
        var arr: std.ArrayListUnmanaged(u8) = .empty;
        try self.write(arr.writer(page.call_arena));
        return arr.items;
    }

    fn write(self: *const URLSearchParams, writer: anytype) !void {
        return kv.urlEncode(self.entries, .query, writer);
    }

    // TODO
    pub fn _sort(_: *URLSearchParams) void {}

    fn encode(self: *const URLSearchParams, writer: anytype) !void {
        return kv.urlEncode(self.entries, .query, writer);
    }
};

// Parse the given query.
fn parseQuery(arena: Allocator, s: []const u8) !kv.List {
    var list = kv.List{};

    const ln = s.len;
    if (ln == 0) {
        return list;
    }

    var query = if (s[0] == '?') s[1..] else s;
    while (query.len > 0) {
        const i = std.mem.indexOfScalarPos(u8, query, 0, '=') orelse query.len;
        const name = query[0..i];

        var value: ?[]const u8 = null;
        if (i < query.len) {
            query = query[i + 1 ..];
            const j = std.mem.indexOfScalarPos(u8, query, 0, '&') orelse query.len;
            value = query[0..j];

            query = if (j < query.len) query[j + 1 ..] else "";
        } else {
            query = "";
        }

        try list.appendOwned(
            arena,
            try unescape(arena, name),
            if (value) |v| try unescape(arena, v) else "",
        );
    }

    return list;
}

fn unescape(arena: Allocator, input: []const u8) ![]const u8 {
    const HEX_CHAR = comptime blk: {
        var all = std.mem.zeroes([256]bool);
        for ('a'..('f' + 1)) |b| all[b] = true;
        for ('A'..('F' + 1)) |b| all[b] = true;
        for ('0'..('9' + 1)) |b| all[b] = true;
        break :blk all;
    };

    const HEX_DECODE = comptime blk: {
        var all = std.mem.zeroes([256]u8);
        for ('a'..('z' + 1)) |b| all[b] = b - 'a' + 10;
        for ('A'..('Z' + 1)) |b| all[b] = b - 'A' + 10;
        for ('0'..('9' + 1)) |b| all[b] = b - '0';
        break :blk all;
    };

    var has_plus = false;
    var unescaped_len = input.len;

    {
        // Figure out if we have any spaces and what the final unescaped length
        // will be (which will let us know if we have anything to unescape in
        // the first place)
        var i: usize = 0;
        while (i < input.len) {
            const c = input[i];
            if (c == '%') {
                if (i + 2 >= input.len or !HEX_CHAR[input[i + 1]] or !HEX_CHAR[input[i + 2]]) {
                    return error.EscapeError;
                }
                i += 3;
                unescaped_len -= 2;
            } else if (c == '+') {
                has_plus = true;
                i += 1;
            } else {
                i += 1;
            }
        }
    }

    // no encoding, and no plus. nothing to unescape
    if (unescaped_len == input.len and has_plus == false) {
        // we always dupe, because we know our caller wants it always duped.
        return arena.dupe(u8, input);
    }

    var unescaped = try arena.alloc(u8, unescaped_len);
    errdefer arena.free(unescaped);

    var input_pos: usize = 0;
    for (0..unescaped_len) |unescaped_pos| {
        switch (input[input_pos]) {
            '+' => {
                unescaped[unescaped_pos] = ' ';
                input_pos += 1;
            },
            '%' => {
                const encoded = input[input_pos + 1 .. input_pos + 3];
                const encoded_as_uint = @as(u16, @bitCast(encoded[0..2].*));
                unescaped[unescaped_pos] = switch (encoded_as_uint) {
                    asUint(u16, "20") => ' ',
                    asUint(u16, "21") => '!',
                    asUint(u16, "22") => '"',
                    asUint(u16, "23") => '#',
                    asUint(u16, "24") => '$',
                    asUint(u16, "25") => '%',
                    asUint(u16, "26") => '&',
                    asUint(u16, "27") => '\'',
                    asUint(u16, "28") => '(',
                    asUint(u16, "29") => ')',
                    asUint(u16, "2A") => '*',
                    asUint(u16, "2B") => '+',
                    asUint(u16, "2C") => ',',
                    asUint(u16, "2F") => '/',
                    asUint(u16, "3A") => ':',
                    asUint(u16, "3B") => ';',
                    asUint(u16, "3D") => '=',
                    asUint(u16, "3F") => '?',
                    asUint(u16, "40") => '@',
                    asUint(u16, "5B") => '[',
                    asUint(u16, "5D") => ']',
                    else => HEX_DECODE[encoded[0]] << 4 | HEX_DECODE[encoded[1]],
                };
                input_pos += 3;
            },
            else => |c| {
                unescaped[unescaped_pos] = c;
                input_pos += 1;
            },
        }
    }
    return unescaped;
}

fn asUint(comptime T: type, comptime string: []const u8) T {
    return @bitCast(string[0..string.len].*);
}

const KeyIterable = iterator.Iterable(kv.KeyIterator, "URLSearchParamsKeyIterator");
const ValueIterable = iterator.Iterable(kv.ValueIterator, "URLSearchParamsValueIterator");
const EntryIterable = iterator.Iterable(kv.EntryIterator, "URLSearchParamsEntryIterator");

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

        .{ "url.search = 'hello=world'", null },
        .{ "url.searchParams.size", "1" },
        .{ "url.searchParams.get('hello')", "world" },

        .{ "url.search = '?over=9000'", null },
        .{ "url.searchParams.size", "1" },
        .{ "url.searchParams.get('over')", "9000" },

        .{ "url.search = ''", null },
        .{ "url.searchParams.size", "0" },

        .{ " const url2 = new URL(url);", null },
        .{ "url2.href", "https://foo.bar/path#fragment" },

        .{ " try { new URL(document.createElement('a')); } catch (e) { e }", "TypeError: invalid argument" },

        .{ " let a = document.createElement('a');", null },
        .{ " a.href = 'https://www.lightpanda.io/over?9000=!!';", null },
        .{ " const url3 = new URL(a);", null },
        .{ "url3.href", "https://www.lightpanda.io/over?9000=%21%21" },
    }, .{});

    try runner.testCases(&.{
        .{ "var url = new URL('https://foo.bar/path?a=~&b=%7E#fragment')", "undefined" },
        .{ "url.searchParams.get('a')", "~" },
        .{ "url.searchParams.get('b')", "~" },
        .{ "url.searchParams.append('c', 'foo')", "undefined" },
        .{ "url.searchParams.get('c')", "foo" },
        .{ "url.searchParams.getAll('c').length", "1" },
        .{ "url.searchParams.getAll('c')[0]", "foo" },
        .{ "url.searchParams.size", "3" },

        // search is dynamic
        .{ "url.search", "?a=~&b=~&c=foo" },
        // href is dynamic
        .{ "url.href", "https://foo.bar/path?a=~&b=~&c=foo#fragment" },

        .{ "url.searchParams.delete('c', 'foo')", "undefined" },
        .{ "url.searchParams.get('c')", "null" },
        .{ "url.searchParams.delete('a')", "undefined" },
        .{ "url.searchParams.get('a')", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "var url = new URL('over?9000', 'https://lightpanda.io')", null },
        .{ "url.href", "https://lightpanda.io/over?9000" },
    }, .{});
}

test "Browser.URLSearchParams" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();
    try runner.testCases(&.{
        .{ "let usp = new URLSearchParams()", null },
        .{ "usp.get('a')", "null" },
        .{ "usp.has('a')", "false" },
        .{ "usp.getAll('a')", "" },
        .{ "usp.delete('a')", "undefined" },

        .{ "usp.set('a', 1)", "undefined" },
        .{ "usp.has('a')", "true" },
        .{ "usp.get('a')", "1" },
        .{ "usp.getAll('a')", "1" },

        .{ "usp.append('a', 2)", "undefined" },
        .{ "usp.has('a')", "true" },
        .{ "usp.get('a')", "1" },
        .{ "usp.getAll('a')", "1,2" },

        .{ "usp.append('b', '3')", "undefined" },
        .{ "usp.has('a')", "true" },
        .{ "usp.get('a')", "1" },
        .{ "usp.getAll('a')", "1,2" },
        .{ "usp.has('b')", "true" },
        .{ "usp.get('b')", "3" },
        .{ "usp.getAll('b')", "3" },

        .{ "let acc = [];", null },
        .{ "for (const key of usp.keys()) { acc.push(key) }; acc;", "a,a,b" },

        .{ "acc = [];", null },
        .{ "for (const value of usp.values()) { acc.push(value) }; acc;", "1,2,3" },

        .{ "acc = [];", null },
        .{ "for (const entry of usp.entries()) { acc.push(entry) }; acc;", "a,1,a,2,b,3" },

        .{ "acc = [];", null },
        .{ "for (const entry of usp) { acc.push(entry) }; acc;", "a,1,a,2,b,3" },

        .{ "usp.delete('a')", "undefined" },
        .{ "usp.has('a')", "false" },
        .{ "usp.has('b')", "true" },

        .{ "acc = [];", null },
        .{ "for (const key of usp.keys()) { acc.push(key) }; acc;", "b" },

        .{ "acc = [];", null },
        .{ "for (const value of usp.values()) { acc.push(value) }; acc;", "3" },

        .{ "acc = [];", null },
        .{ "for (const entry of usp.entries()) { acc.push(entry) }; acc;", "b,3" },

        .{ "acc = [];", null },
        .{ "for (const entry of usp) { acc.push(entry) }; acc;", "b,3" },
    }, .{});

    try runner.testCases(&.{
        .{ "usp = new URLSearchParams('?hello')", null },
        .{ "usp.get('hello')", "" },

        .{ "usp = new URLSearchParams('?abc=')", null },
        .{ "usp.get('abc')", "" },

        .{ "usp = new URLSearchParams('?abc=123&')", null },
        .{ "usp.get('abc')", "123" },
        .{ "usp.size", "1" },

        .{ "var fd = new FormData()", null },
        .{ "fd.append('a', '1')", null },
        .{ "fd.append('a', '2')", null },
        .{ "fd.append('b', '3')", null },
        .{ "ups = new URLSearchParams(fd)", null },
        .{ "ups.size", "3" },
        .{ "ups.getAll('a')", "1,2" },
        .{ "ups.getAll('b')", "3" },
        .{ "fd.delete('a')", null }, // the two aren't linked, it created a copy
        .{ "ups.size", "3" },
    }, .{});
}
