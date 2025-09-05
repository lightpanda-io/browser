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
const URL = @import("../../url.zig").URL;
const Page = @import("../page.zig").Page;

const v8 = @import("v8");
const Env = @import("../env.zig").Env;

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
    headers: *Headers,
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
                    const key = try arena.dupe(u8, entry.key_ptr.*);
                    const value = try arena.dupe(u8, entry.value_ptr.*);
                    try headers.put(arena, key, value);
                }
            },
        }
    }

    return .{
        .headers = headers,
    };
}

pub fn clone(self: *const Headers, allocator: std.mem.Allocator) !Headers {
    return Headers{
        .headers = try self.headers.clone(allocator),
    };
}

pub fn append(self: *Headers, name: []const u8, value: []const u8, allocator: std.mem.Allocator) !void {
    const gop = try self.headers.getOrPut(allocator, name);

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

pub const HeaderEntryIterator = struct {
    slot: [][]const u8,
    iter: *HeaderHashMap.Iterator,

    // TODO: these SHOULD be in lexigraphical order but I'm not sure how actually
    // important that is.
    pub fn _next(self: *HeaderEntryIterator) !?[]const []const u8 {
        if (self.iter.next()) |entry| {
            self.slot[0] = entry.key_ptr.*;
            self.slot[1] = entry.value_ptr.*;
            return self.slot;
        } else {
            return null;
        }
    }
};

pub fn _entries(self: *const Headers, page: *Page) !HeaderEntryIterator {
    const iter = try page.arena.create(HeaderHashMap.Iterator);
    iter.* = self.headers.iterator();

    return .{ .slot = try page.arena.alloc([]const u8, 2), .iter = iter };
}

pub fn _forEach(self: *Headers, callback_fn: Env.Function, this_arg: ?Env.JsObject) !void {
    var iter = self.headers.iterator();

    if (this_arg) |this| {
        while (iter.next()) |entry| {
            try callback_fn.callWithThis(
                void,
                this,
                .{ entry.key_ptr.*, entry.value_ptr.*, self },
            );
        }
    } else {
        while (iter.next()) |entry| {
            try callback_fn.call(
                void,
                .{ entry.key_ptr.*, entry.value_ptr.*, self },
            );
        }
    }
}

pub fn _get(self: *const Headers, name: []const u8) ?[]const u8 {
    return self.headers.get(name);
}

pub fn _has(self: *const Headers, name: []const u8) bool {
    return self.headers.contains(name);
}

pub const HeaderKeyIterator = struct {
    iter: *HeaderHashMap.KeyIterator,

    pub fn _next(self: *HeaderKeyIterator) !?[]const u8 {
        if (self.iter.next()) |key| {
            return key.*;
        } else {
            return null;
        }
    }
};

pub fn _keys(self: *const Headers, page: *Page) !HeaderKeyIterator {
    const iter = try page.arena.create(HeaderHashMap.KeyIterator);
    iter.* = self.headers.keyIterator();

    return .{ .iter = iter };
}

pub fn _set(self: *Headers, name: []const u8, value: []const u8, page: *Page) !void {
    const arena = page.arena;

    const gop = try self.headers.getOrPut(arena, name);
    gop.value_ptr.* = try arena.dupe(u8, value);
}

pub const HeaderValueIterator = struct {
    iter: *HeaderHashMap.ValueIterator,

    pub fn _next(self: *HeaderValueIterator) !?[]const u8 {
        if (self.iter.next()) |value| {
            return value.*;
        } else {
            return null;
        }
    }
};

pub fn _values(self: *const Headers, page: *Page) !HeaderValueIterator {
    const iter = try page.arena.create(HeaderHashMap.ValueIterator);
    iter.* = self.headers.valueIterator();
    return .{ .iter = iter };
}

const testing = @import("../../testing.zig");
test "fetch: headers" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let empty_headers = new Headers()", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "let headers = new Headers([['Set-Cookie', 'name=world']])", "undefined" },
        .{ "headers.get('set-cookie')", "name=world" },
    }, .{});

    // adapted from the mdn examples
    try runner.testCases(&.{
        .{ "const myHeaders = new Headers();", "undefined" },
        .{ "myHeaders.append('Content-Type', 'image/jpeg')", "undefined" },
        .{ "myHeaders.has('Picture-Type')", "false" },
        .{ "myHeaders.get('Content-Type')", "image/jpeg" },
        .{ "myHeaders.append('Content-Type', 'image/png')", "undefined" },
        .{ "myHeaders.get('Content-Type')", "image/jpeg, image/png" },
        .{ "myHeaders.delete('Content-Type')", "undefined" },
        .{ "myHeaders.get('Content-Type')", "null" },
        .{ "myHeaders.set('Picture-Type', 'image/svg')", "undefined" },
        .{ "myHeaders.get('Picture-Type')", "image/svg" },
        .{ "myHeaders.has('Picture-Type')", "true" },
    }, .{});
}
