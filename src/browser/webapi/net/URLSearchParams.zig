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
const js = @import("../../js/js.zig");

const log = @import("../../../log.zig");
const String = @import("../../../string.zig").String;
const Allocator = std.mem.Allocator;

const FormData = @import("FormData.zig");
const KeyValueList = @import("../KeyValueList.zig");
const Execution = js.Execution;

const URLSearchParams = @This();

_arena: Allocator,
_params: KeyValueList,

const InitOpts = union(enum) {
    form_data: *FormData,
    value: js.Value,
    query_string: []const u8,
};

pub fn init(opts_: ?InitOpts, exec: *const Execution) !*URLSearchParams {
    const arena = exec.arena;
    const params: KeyValueList = blk: {
        const opts = opts_ orelse break :blk .empty;
        switch (opts) {
            .query_string => |qs| break :blk try paramsFromString(arena, qs, exec.buf),
            .form_data => |fd| break :blk try KeyValueList.copy(arena, fd._list),
            .value => |js_val| {
                // Order matters here; Array is also an Object.
                if (js_val.isArray()) {
                    break :blk try paramsFromArray(arena, js_val.toArray());
                }
                if (js_val.isObject()) {
                    // normalizer is null, so page won't be used
                    break :blk try KeyValueList.fromJsObject(arena, js_val.toObject(), null, exec.buf);
                }
                if (js_val.isString()) |js_str| {
                    break :blk try paramsFromString(arena, try js_str.toSliceWithAlloc(arena), exec.buf);
                }
                return error.InvalidArgument;
            },
        }
    };

    return exec._factory.create(URLSearchParams{
        ._arena = arena,
        ._params = params,
    });
}

pub fn updateFromString(self: *URLSearchParams, query_string: []const u8, exec: *const Execution) !void {
    self._params = try paramsFromString(self._arena, query_string, exec.buf);
}

pub fn getSize(self: *const URLSearchParams) usize {
    return self._params.len();
}

pub fn get(self: *const URLSearchParams, name: []const u8) ?[]const u8 {
    return self._params.get(name);
}

pub fn getAll(self: *const URLSearchParams, name: []const u8, exec: *const Execution) ![]const []const u8 {
    return self._params.getAll(exec.call_arena, name);
}

pub fn has(self: *const URLSearchParams, name: []const u8) bool {
    return self._params.has(name);
}

pub fn set(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
    return self._params.set(self._arena, name, value);
}

pub fn append(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
    return self._params.append(self._arena, name, value);
}

pub fn delete(self: *URLSearchParams, name: []const u8, value: ?[]const u8) void {
    self._params.delete(name, value);
}

pub fn keys(self: *URLSearchParams, exec: *const Execution) !*KeyValueList.KeyIterator {
    return KeyValueList.KeyIterator.init(.{ .list = self, .kv = &self._params }, exec);
}

pub fn values(self: *URLSearchParams, exec: *const Execution) !*KeyValueList.ValueIterator {
    return KeyValueList.ValueIterator.init(.{ .list = self, .kv = &self._params }, exec);
}

pub fn entries(self: *URLSearchParams, exec: *const Execution) !*KeyValueList.EntryIterator {
    return KeyValueList.EntryIterator.init(.{ .list = self, .kv = &self._params }, exec);
}

pub fn toString(self: *const URLSearchParams, writer: *std.Io.Writer) !void {
    // URLSearchParams always uses UTF-8 per the URL Standard
    return self._params.urlEncode(.query, null, "UTF-8", writer);
}

pub fn format(self: *const URLSearchParams, writer: *std.Io.Writer) !void {
    return self.toString(writer);
}

pub fn forEach(self: *URLSearchParams, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._params._entries.items) |entry| {
        cb.call(void, .{ entry.value.str(), entry.name.str(), self }) catch |err| {
            // this is a non-JS error
            log.warn(.js, "URLSearchParams.forEach", .{ .err = err });
        };
    }
}

pub fn sort(self: *URLSearchParams) void {
    std.mem.sort(KeyValueList.Entry, self._params._entries.items, {}, struct {
        fn cmp(_: void, a: KeyValueList.Entry, b: KeyValueList.Entry) bool {
            return std.mem.order(u8, a.name.str(), b.name.str()) == .lt;
        }
    }.cmp);
}

fn paramsFromArray(allocator: Allocator, array: js.Array) !KeyValueList {
    const array_len = array.len();
    if (array_len == 0) {
        return .empty;
    }

    var params = KeyValueList.init();
    try params.ensureTotalCapacity(allocator, array_len);
    // TODO: Release `params` on error.

    var i: u32 = 0;
    while (i < array_len) : (i += 1) {
        const item = try array.get(i);
        if (!item.isArray()) return error.InvalidArgument;

        const as_array = item.toArray();
        // Need 2 items for KV.
        if (as_array.len() != 2) return error.InvalidArgument;

        const name_val = try as_array.get(0);
        const value_val = try as_array.get(1);

        params._entries.appendAssumeCapacity(.{
            .name = try name_val.toSSOWithAlloc(allocator),
            .value = try value_val.toSSOWithAlloc(allocator),
        });
    }

    return params;
}

fn paramsFromString(allocator: Allocator, input_: []const u8, buf: []u8) !KeyValueList {
    if (input_.len == 0) {
        return .empty;
    }

    var input = input_;
    if (input[0] == '?') {
        input = input[1..];
    }

    // After stripping '?', check if string is empty
    if (input.len == 0) {
        return .empty;
    }

    var params = KeyValueList.init();

    var it = std.mem.splitScalar(u8, input, '&');
    while (it.next()) |entry| {
        // Skip empty entries (from trailing &, or &&)
        if (entry.len == 0) continue;

        var name: String = undefined;
        var value: String = undefined;

        if (std.mem.indexOfScalarPos(u8, entry, 0, '=')) |idx| {
            name = try unescape(allocator, entry[0..idx], buf);
            value = try unescape(allocator, entry[idx + 1 ..], buf);
        } else {
            name = try unescape(allocator, entry, buf);
            value = String.init(undefined, "", .{}) catch unreachable;
        }

        // optimized, unescape returns a String directly (Because unescape may
        // have to dupe itself, so it knows how best to create the String)
        try params._entries.append(allocator, .{
            .name = name,
            .value = value,
        });
    }

    return params;
}

fn unescape(arena: Allocator, value: []const u8, buf: []u8) !String {
    if (value.len == 0) {
        return String.init(undefined, "", .{});
    }

    var has_plus = false;
    var unescaped_len = value.len;

    var in_i: usize = 0;
    while (in_i < value.len) {
        const b = value[in_i];
        if (b == '%') {
            if (in_i + 2 >= value.len or !std.ascii.isHex(value[in_i + 1]) or !std.ascii.isHex(value[in_i + 2])) {
                return error.InvalidEscapeSequence;
            }
            in_i += 3;
            unescaped_len -= 2;
        } else if (b == '+') {
            has_plus = true;
            in_i += 1;
        } else {
            in_i += 1;
        }
    }

    // no encoding, and no plus. nothing to unescape
    if (unescaped_len == value.len and !has_plus) {
        return String.init(arena, value, .{});
    }

    var out = buf;
    var duped = false;
    if (buf.len < unescaped_len) {
        out = try arena.alloc(u8, unescaped_len);
        duped = true;
    }

    in_i = 0;
    for (0..unescaped_len) |i| {
        const b = value[in_i];
        if (b == '%') {
            out[i] = decodeHex(value[in_i + 1]) << 4 | decodeHex(value[in_i + 2]);
            in_i += 3;
        } else if (b == '+') {
            out[i] = ' ';
            in_i += 1;
        } else {
            out[i] = b;
            in_i += 1;
        }
    }

    return String.init(arena, out[0..unescaped_len], .{ .dupe = !duped });
}

const HEX_DECODE_ARRAY = blk: {
    var all: ['f' - '0' + 1]u8 = undefined;
    for ('0'..('9' + 1)) |b| all[b - '0'] = b - '0';
    for ('A'..('F' + 1)) |b| all[b - '0'] = b - 'A' + 10;
    for ('a'..('f' + 1)) |b| all[b - '0'] = b - 'a' + 10;
    break :blk all;
};

inline fn decodeHex(char: u8) u8 {
    return @as([*]const u8, @ptrFromInt((@intFromPtr(&HEX_DECODE_ARRAY) - @as(usize, '0'))))[char];
}

pub const Iterator = struct {
    index: u32 = 0,
    list: *const URLSearchParams,

    const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Execution) !?Iterator.Entry {
        const index = self.index;
        const items = self.list._params.items;
        if (index >= items.len) {
            return null;
        }
        self.index = index + 1;

        const e = &items[index];
        return .{ e.name.str(), e.value.str() };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(URLSearchParams);

    pub const Meta = struct {
        pub const name = "URLSearchParams";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(URLSearchParams.init, .{});
    pub const has = bridge.function(URLSearchParams.has, .{});
    pub const get = bridge.function(URLSearchParams.get, .{});
    pub const set = bridge.function(URLSearchParams.set, .{});
    pub const append = bridge.function(URLSearchParams.append, .{});
    pub const getAll = bridge.function(URLSearchParams.getAll, .{});
    pub const delete = bridge.function(URLSearchParams.delete, .{});
    pub const size = bridge.accessor(URLSearchParams.getSize, null, .{});
    pub const keys = bridge.function(URLSearchParams.keys, .{});
    pub const values = bridge.function(URLSearchParams.values, .{});
    pub const entries = bridge.function(URLSearchParams.entries, .{});
    pub const symbol_iterator = bridge.iterator(URLSearchParams.entries, .{});
    pub const forEach = bridge.function(URLSearchParams.forEach, .{});
    pub const sort = bridge.function(URLSearchParams.sort, .{});

    pub const toString = bridge.function(_toString, .{});
    fn _toString(self: *const URLSearchParams, exec: *const Execution) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(exec.call_arena);
        try self.toString(&buf.writer);
        return buf.written();
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: URLSearchParams" {
    try testing.htmlRunner("net/url_search_params.html", .{});
}
