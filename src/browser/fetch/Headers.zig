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
const js = @import("../js/js.zig");
const log = @import("../../log.zig");
const URL = @import("../../url.zig").URL;
const Page = @import("../page.zig").Page;

const iterator = @import("../iterator/iterator.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/Headers
const Headers = @This();

// Case-Insensitive String HashMap.
// This allows us to avoid having to allocate lowercase keys all the time.
const HeaderHashMap = std.HashMapUnmanaged([]const u8, []const u8, struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        var buf: [64]u8 = undefined;
        var hasher = std.hash.Wyhash.init(s.len);

        var key = s;
        while (key.len >= 64) {
            const lower = std.ascii.lowerString(buf[0..], key[0..64]);
            hasher.update(lower);
            key = key[64..];
        }

        if (key.len > 0) {
            const lower = std.ascii.lowerString(buf[0..key.len], key);
            hasher.update(lower);
        }

        return hasher.final();
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
}, 80);

headers: HeaderHashMap = .empty,

// They can either be:
//
// 1. An array of string pairs.
// 2. An object with string keys to string values.
// 3. Another Headers object.
pub const HeadersInit = union(enum) {
    // List of Pairs of []const u8
    strings: []const [2][]const u8,
    // Headers
    headers: *Headers,
    // Mappings
    object: js.Object,
};

pub fn constructor(_init: ?HeadersInit, page: *Page) !Headers {
    const arena = page.arena;
    var headers: HeaderHashMap = .empty;

    if (_init) |init| {
        switch (init) {
            .strings => |kvs| {
                for (kvs) |pair| {
                    const key = try arena.dupe(u8, pair[0]);
                    const value = try arena.dupe(u8, pair[1]);

                    try headers.put(arena, key, value);
                }
            },
            .headers => |hdrs| {
                var iter = hdrs.headers.iterator();
                while (iter.next()) |entry| {
                    try headers.put(arena, entry.key_ptr.*, entry.value_ptr.*);
                }
            },
            .object => |obj| {
                var iter = obj.nameIterator();
                while (try iter.next()) |name_value| {
                    const name = try name_value.toString(arena);
                    const value = try obj.get(name);
                    const value_string = try value.toString(arena);

                    try headers.put(arena, name, value_string);
                }
            },
        }
    }

    return .{
        .headers = headers,
    };
}

pub fn append(self: *Headers, name: []const u8, value: []const u8, allocator: std.mem.Allocator) !void {
    const key = try allocator.dupe(u8, name);
    const gop = try self.headers.getOrPut(allocator, key);

    if (gop.found_existing) {
        // If we found it, append the value.
        const new_value = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ gop.value_ptr.*, value });
        gop.value_ptr.* = new_value;
    } else {
        // Otherwise, we should just put it in.
        gop.value_ptr.* = try allocator.dupe(u8, value);
    }
}

pub fn _append(self: *Headers, name: []const u8, value: []const u8, page: *Page) !void {
    const arena = page.arena;
    try self.append(name, value, arena);
}

pub fn _delete(self: *Headers, name: []const u8) void {
    _ = self.headers.remove(name);
}

pub const HeadersEntryIterator = struct {
    slot: [2][]const u8,
    iter: HeaderHashMap.Iterator,

    // TODO: these SHOULD be in lexigraphical order but I'm not sure how actually
    // important that is.
    pub fn _next(self: *HeadersEntryIterator) ?[2][]const u8 {
        if (self.iter.next()) |entry| {
            self.slot[0] = entry.key_ptr.*;
            self.slot[1] = entry.value_ptr.*;
            return self.slot;
        } else {
            return null;
        }
    }
};

pub fn _entries(self: *const Headers) HeadersEntryIterable {
    return .{
        .inner = .{
            .slot = undefined,
            .iter = self.headers.iterator(),
        },
    };
}

pub fn _forEach(self: *Headers, callback_fn: js.Function, this_arg: ?js.Object) !void {
    var iter = self.headers.iterator();

    const cb = if (this_arg) |this| try callback_fn.withThis(this) else callback_fn;

    while (iter.next()) |entry| {
        try cb.call(void, .{ entry.key_ptr.*, entry.value_ptr.*, self });
    }
}

pub fn _get(self: *const Headers, name: []const u8) ?[]const u8 {
    return self.headers.get(name);
}

pub fn _has(self: *const Headers, name: []const u8) bool {
    return self.headers.contains(name);
}

pub const HeadersKeyIterator = struct {
    iter: HeaderHashMap.KeyIterator,

    pub fn _next(self: *HeadersKeyIterator) ?[]const u8 {
        if (self.iter.next()) |key| {
            return key.*;
        } else {
            return null;
        }
    }
};

pub fn _keys(self: *const Headers) HeadersKeyIterable {
    return .{ .inner = .{ .iter = self.headers.keyIterator() } };
}

pub fn _set(self: *Headers, name: []const u8, value: []const u8, page: *Page) !void {
    const arena = page.arena;

    const key = try arena.dupe(u8, name);
    const gop = try self.headers.getOrPut(arena, key);
    gop.value_ptr.* = try arena.dupe(u8, value);
}

pub const HeadersValueIterator = struct {
    iter: HeaderHashMap.ValueIterator,

    pub fn _next(self: *HeadersValueIterator) ?[]const u8 {
        if (self.iter.next()) |value| {
            return value.*;
        } else {
            return null;
        }
    }
};

pub fn _values(self: *const Headers) HeadersValueIterable {
    return .{ .inner = .{ .iter = self.headers.valueIterator() } };
}

pub const HeadersKeyIterable = iterator.Iterable(HeadersKeyIterator, "HeadersKeyIterator");
pub const HeadersValueIterable = iterator.Iterable(HeadersValueIterator, "HeadersValueIterator");
pub const HeadersEntryIterable = iterator.Iterable(HeadersEntryIterator, "HeadersEntryIterator");

const testing = @import("../../testing.zig");
test "fetch: Headers" {
    try testing.htmlRunner("fetch/headers.html");
}
