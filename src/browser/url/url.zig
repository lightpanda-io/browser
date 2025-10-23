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
const Writer = std.Io.Writer;
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
    /// We prefer in-house search params solution here;
    /// ada's search params impl use more memory.
    /// It also offers it's own iterator implementation
    /// where we'd like to use ours.
    search_params: URLSearchParams,

    pub const empty = URL{
        .internal = null,
        .search_params = .{},
    };

    // You can use an existing URL object for either argument, and it will be
    // stringified from the object's href property.
    const ConstructorArg = union(enum) {
        string: []const u8,
        url: *const URL,
        element: *parser.Element,

        fn toString(self: ConstructorArg, page: *Page) ![]const u8 {
            return switch (self) {
                .string => |s| s,
                .url => |url| url._toString(page),
                .element => |e| {
                    const attrib = try parser.elementGetAttribute(@ptrCast(e), "href") orelse {
                        return error.InvalidArgument;
                    };

                    return attrib;
                },
            };
        }
    };

    pub fn constructor(url: ConstructorArg, maybe_base: ?ConstructorArg, page: *Page) !URL {
        const url_str = try url.toString(page);

        const internal = try blk: {
            if (maybe_base) |base| {
                break :blk ada.parseWithBase(url_str, try base.toString(page));
            }

            break :blk ada.parse(url_str);
        };

        return .{
            .internal = internal,
            .search_params = try prepareSearchParams(page.arena, internal),
        };
    }

    pub fn destructor(self: *const URL) void {
        // Not tracked by arena.
        return ada.free(self.internal);
    }

    /// Only to be used by `Location` API. `url` MUST NOT provide search params.
    pub fn initForLocation(url: []const u8) !URL {
        return .{ .internal = try ada.parse(url), .search_params = .{} };
    }

    /// Reinitializes the URL by parsing given `url`. Search params can be provided.
    pub fn reinit(self: *URL, url: []const u8, page: *Page) !void {
        _ = ada.setHref(self.internal, url);
        if (!ada.isValid(self.internal)) return error.Internal;

        self.search_params = try prepareSearchParams(page.arena, self.internal);
    }

    /// Prepares a `URLSearchParams` from given `internal`.
    /// Resets `search` of `internal`.
    fn prepareSearchParams(arena: Allocator, internal: ada.URL) !URLSearchParams {
        const maybe_search = ada.getSearchNullable(internal);
        // Empty.
        if (maybe_search.data == null) return .{};

        const search = maybe_search.data[0..maybe_search.length];
        const search_params = URLSearchParams.initFromString(arena, search);
        // After a call to this function, search params are tracked by
        // `search_params`. So we reset the internal's search.
        ada.clearSearch(internal);

        return search_params;
    }

    pub fn clearPort(self: *const URL) void {
        return ada.clearPort(self.internal);
    }

    pub fn clearHash(self: *const URL) void {
        return ada.clearHash(self.internal);
    }

    /// Returns a boolean indicating whether or not an absolute URL,
    /// or a relative URL combined with a base URL, are parsable and valid.
    pub fn static_canParse(url: ConstructorArg, maybe_base: ?ConstructorArg, page: *Page) !bool {
        const url_str = try url.toString(page);

        if (maybe_base) |base| {
            return ada.canParseWithBase(url_str, try base.toString(page));
        }

        return ada.canParse(url_str);
    }

    /// Alias to get_href.
    pub fn _toString(self: *const URL, page: *Page) ![]const u8 {
        return self.get_href(page);
    }

    // Getters.

    pub fn get_searchParams(self: *URL) *URLSearchParams {
        return &self.search_params;
    }

    pub fn get_origin(self: *const URL, page: *Page) ![]const u8 {
        // `ada.getOriginNullable` allocates memory in order to find the `origin`.
        // We'd like to use our arena allocator for such case;
        // so here we allocate the `origin` in page arena and free the original.
        const maybe_origin = ada.getOriginNullable(self.internal);
        if (maybe_origin.data == null) {
            return "";
        }
        defer ada.freeOwnedString(maybe_origin);

        const origin = maybe_origin.data[0..maybe_origin.length];
        return page.call_arena.dupe(u8, origin);
    }

    pub fn get_href(self: *const URL, page: *Page) ![]const u8 {
        var w: Writer.Allocating = .init(page.arena);

        // If URL is not valid, return immediately.
        if (!ada.isValid(self.internal)) {
            return "";
        }

        // Since the earlier check passed, this can't be null.
        const str = ada.getHrefNullable(self.internal);
        const href = str.data[0..str.length];
        // This can't be null either.
        const comps = ada.getComponents(self.internal);
        // If hash provided, we write it after we fit-in the search params.
        const has_hash = comps.hash_start != ada.URLOmitted;
        const href_part = if (has_hash) href[0..comps.hash_start] else href;
        try w.writer.writeAll(href_part);

        // Write search params if provided.
        if (self.search_params.get_size() > 0) {
            try w.writer.writeByte('?');
            try self.search_params.write(&w.writer);
        }

        // Write hash if provided before.
        const hash = self.get_hash();
        try w.writer.writeAll(hash);

        return w.written();
    }

    pub fn get_username(self: *const URL) []const u8 {
        const username = ada.getUsernameNullable(self.internal);
        if (username.data == null) {
            return "";
        }

        return username.data[0..username.length];
    }

    pub fn get_password(self: *const URL) []const u8 {
        const password = ada.getPasswordNullable(self.internal);
        if (password.data == null) {
            return "";
        }

        return password.data[0..password.length];
    }

    pub fn get_port(self: *const URL) []const u8 {
        const port = ada.getPortNullable(self.internal);
        if (port.data == null) {
            return "";
        }

        return port.data[0..port.length];
    }

    pub fn get_hash(self: *const URL) []const u8 {
        const hash = ada.getHashNullable(self.internal);
        if (hash.data == null) {
            return "";
        }

        return hash.data[0..hash.length];
    }

    pub fn get_host(self: *const URL) []const u8 {
        const host = ada.getHostNullable(self.internal);
        if (host.data == null) {
            return "";
        }

        return host.data[0..host.length];
    }

    pub fn get_hostname(self: *const URL) []const u8 {
        const hostname = ada.getHostnameNullable(self.internal);
        if (hostname.data == null) {
            return "";
        }

        return hostname.data[0..hostname.length];
    }

    pub fn get_pathname(self: *const URL) []const u8 {
        const path = ada.getPathnameNullable(self.internal);
        // Return a slash if path is null.
        if (path.data == null) {
            return "/";
        }

        return path.data[0..path.length];
    }

    /// get_search depends on the current state of `search_params`.
    pub fn get_search(self: *const URL, page: *Page) ![]const u8 {
        const arena = page.arena;

        if (self.search_params.get_size() == 0) {
            return "";
        }

        var buf: std.ArrayListUnmanaged(u8) = .{};
        try buf.append(arena, '?');
        try self.search_params.encode(buf.writer(arena));
        return buf.items;
    }

    pub fn get_protocol(self: *const URL) []const u8 {
        const protocol = ada.getProtocolNullable(self.internal);
        if (protocol.data == null) {
            return "";
        }

        return protocol.data[0..protocol.length];
    }

    // Setters.

    /// Ada-url don't define any errors, so we just prefer one unified
    /// `Internal` error for failing cases.
    const SetterError = error{Internal};

    pub fn set_href(self: *URL, input: []const u8, page: *Page) !void {
        _ = ada.setHref(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
        // Can't call `get_search` here since it uses `search_params`.
        self.search_params = try prepareSearchParams(page.arena, self.internal);
    }

    pub fn set_host(self: *const URL, input: []const u8) SetterError!void {
        _ = ada.setHost(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }

    pub fn set_hostname(self: *const URL, input: []const u8) SetterError!void {
        _ = ada.setHostname(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }

    pub fn set_protocol(self: *const URL, input: []const u8) SetterError!void {
        _ = ada.setProtocol(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }

    pub fn set_username(self: *const URL, input: []const u8) SetterError!void {
        _ = ada.setUsername(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }

    pub fn set_password(self: *const URL, input: []const u8) SetterError!void {
        _ = ada.setPassword(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }

    pub fn set_port(self: *const URL, input: []const u8) SetterError!void {
        _ = ada.setPort(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }

    pub fn set_pathname(self: *const URL, input: []const u8) SetterError!void {
        _ = ada.setPathname(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }

    pub fn set_search(self: *URL, maybe_input: ?[]const u8, page: *Page) !void {
        self.search_params = .{};
        if (maybe_input) |input| {
            self.search_params = try .initFromString(page.arena, input);
        }
    }

    pub fn set_hash(self: *const URL, input: []const u8) !void {
        ada.setHash(self.internal, input);
        if (!ada.isValid(self.internal)) return error.Internal;
    }
};

pub const URLSearchParams = struct {
    entries: kv.List = .{},

    pub const ConstructorOptions = union(enum) {
        query_string: []const u8,
        form_data: *const FormData,
        object: js.Object,
    };

    pub fn constructor(maybe_options: ?ConstructorOptions, page: *Page) !URLSearchParams {
        const options = maybe_options orelse return .{};

        const arena = page.arena;
        return switch (options) {
            .query_string => |string| .{ .entries = try parseQuery(arena, string) },
            .form_data => |form_data| .{ .entries = try form_data.entries.clone(arena) },
            .object => |object| {
                var it = object.nameIterator();

                var entries = kv.List{};
                try entries.ensureTotalCapacity(arena, it.count);

                while (try it.next()) |js_name| {
                    const name = try js_name.toString(arena);
                    const js_value = try object.get(name);
                    const value = try js_value.toString(arena);

                    entries.appendOwnedAssumeCapacity(name, value);
                }

                return .{ .entries = entries };
            },
        };
    }

    /// Initializes URLSearchParams from a query string.
    pub fn initFromString(arena: Allocator, query_string: []const u8) !URLSearchParams {
        return .{ .entries = try parseQuery(arena, query_string) };
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

    pub fn _toString(self: *const URLSearchParams, page: *Page) ![]const u8 {
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
test "Browser: URL" {
    try testing.htmlRunner("url/url.html");
}

test "Browser: URLSearchParams" {
    try testing.htmlRunner("url/url_search_params.html");
}
