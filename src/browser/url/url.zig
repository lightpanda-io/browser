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
const ada = @import("ada");

const js = @import("../js/js.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;
const FormData = @import("../xhr/form_data.zig").FormData;

const kv = @import("../key_value.zig");
const iterator = @import("../iterator/iterator.zig");

pub const Interfaces = .{
    URL,
    URLSearchParams,
    KeyIterable,
    ValueIterable,
    EntryIterable,
};

/// https://developer.mozilla.org/en-US/docs/Web/API/URL/URL
pub const URL = struct {
    internal: ada.URL,

    // You can use an existing URL object for either argument, and it will be
    // stringified from the object's href property.
    pub const ConstructorArg = union(enum) {
        url: *URL,
        element: *parser.Element,
        string: []const u8,

        fn toString(self: *const ConstructorArg) error{Invalid}![]const u8 {
            return switch (self) {
                .string => |s| s,
                .url => |url| url._toString(),
                .element => |e| parser.elementGetAttribute(@ptrCast(e), "href") orelse error.Invalid,
            };
        }
    };

    pub fn constructor(url: ConstructorArg, maybe_base: ?ConstructorArg, _: *Page) !URL {
        const u = blk: {
            const url_str = try url.toString();
            if (maybe_base) |base| {
                break :blk ada.parseWithBase(url_str, try base.toString());
            }

            break :blk ada.parse(url_str);
        };

        return .{ .url = u };
    }

    pub fn destructor(self: *const URL) void {
        ada.free(self.internal);
    }

    pub fn initWithoutSearchParams(uri: std.Uri) URL {
        return .{ .uri = uri, .search_params = .{} };
    }
    pub fn _toString(self: *const URL) []const u8 {
        return ada.getHref(self.internal);
    }

    // Getters.

    pub fn get_origin(self: *const URL, page: *Page) ![]const u8 {
        const arena = page.arena;
        // `ada.getOrigin` allocates memory in order to find the `origin`.
        // We'd like to use our arena allocator for such case;
        // so here we allocate the `origin` in page arena and free the original.
        const origin = ada.getOrigin(self.internal);
        // `OwnedString` itself is not heap allocated so this is safe.
        defer ada.freeOwnedString(.{ .data = origin.ptr, .length = origin.len });

        return arena.dupe(u8, origin);
    }

    pub fn get_href(self: *const URL) []const u8 {
        return ada.getHref(self.internal);
    }

    pub fn get_username(self: *const URL) []const u8 {
        return ada.getUsername(self.internal);
    }

    pub fn get_password(self: *const URL) []const u8 {
        return ada.getPassword(self.internal);
    }

    pub fn get_port(self: *const URL) []const u8 {
        return ada.getPort(self.internal);
    }

    pub fn get_hash(self: *const URL) []const u8 {
        return ada.getHash(self.internal);
    }

    pub fn get_host(self: *const URL) []const u8 {
        return ada.getHost(self.internal);
    }

    pub fn get_hostname(self: *const URL) []const u8 {
        return ada.getHostname(self.internal);
    }

    pub fn get_pathname(self: *const URL) []const u8 {
        return ada.getPathname(self.internal);
    }

    pub fn get_search(self: *const URL) []const u8 {
        return ada.getSearch(self.internal);
    }

    pub fn get_protocol(self: *const URL) []const u8 {
        return ada.getProtocol(self.internal);
    }
};

pub const URLSearchParams = struct {
    internal: ada.URLSearchParams,

    pub const ConstructorOptions = union(enum) {
        string: []const u8,
        form_data: *const FormData,
        object: js.JsObject,
    };
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
test "Browser: URL" {
    try testing.htmlRunner("url/url.html");
}

test "Browser: URLSearchParams" {
    try testing.htmlRunner("url/url_search_params.html");
}
