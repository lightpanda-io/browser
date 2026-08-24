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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const FormData = @import("FormData.zig");
const KeyValueList = @import("../KeyValueList.zig");

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{
        URLSearchParams,
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

const URLSearchParams = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_params: KeyValueList,

const InitOpts = union(enum) {
    form_data: *FormData,
    value: js.Value,
    query_string: []const u8,
};

pub fn init(opts_: ?InitOpts, exec: *const Execution) !*URLSearchParams {
    const arena = try exec.getArena(.small, "URLSearchParams");
    errdefer arena.release();

    const params: KeyValueList = blk: {
        const opts = opts_ orelse break :blk .empty;
        switch (opts) {
            .query_string => |qs| break :blk try paramsFromString(arena.allocator(), qs, exec.buf),
            .form_data => |fd| break :blk try fd.toKeyValueList(arena.allocator()),
            .value => |js_val| {
                // Order matters here; Array is also an Object.
                if (js_val.isArray()) {
                    break :blk try paramsFromArray(arena.allocator(), js_val.toArray());
                }
                if (js_val.isObject()) {
                    // Per the URL spec, an iterable init (URLSearchParams,
                    // Map, ...) should be walked via its @@iterator. We
                    // don't have a generic iterable path yet; cover the
                    // common case of `new URLSearchParams(otherUSP)` so
                    // the prototype-method-leak doesn't just turn into a
                    // silent empty querystring.
                    if (js_val.toZig(*URLSearchParams)) |other| {
                        break :blk try KeyValueList.copy(arena.allocator(), other._params);
                    } else |_| {}
                    // normalizer is null, so frame won't be used
                    break :blk try KeyValueList.fromJsObject(arena.allocator(), js_val.toObject(), null, exec.buf);
                }
                if (js_val.isString()) |js_str| {
                    break :blk try paramsFromString(arena.allocator(), try js_str.toSliceWithAlloc(arena.allocator()), exec.buf);
                }
                return error.InvalidArgument;
            },
        }
    };

    const self = try arena.create(URLSearchParams);
    self.* = .{
        ._arena = arena,
        ._params = params,
    };
    return self;
}

pub fn deinit(self: *URLSearchParams, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *URLSearchParams, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *URLSearchParams) void {
    self._rc.acquire();
}

pub fn updateFromString(self: *URLSearchParams, query_string: []const u8, exec: *const Execution) !void {
    self._params = try paramsFromString(self._arena.allocator(), query_string, exec.buf);
}

pub fn getSize(self: *const URLSearchParams) usize {
    return self._params.len();
}

pub fn get(self: *const URLSearchParams, name: []const u8) ?[]const u8 {
    return self._params.get(name);
}

pub fn getAll(self: *const URLSearchParams, name: []const u8, exec: *const Execution) ![]const []const u8 {
    return self._params.getAll(exec.local_arena, name);
}

pub fn has(self: *const URLSearchParams, name: []const u8, value: ?[]const u8) bool {
    return self._params.has(name, value);
}

pub fn set(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
    return self._params.set(self._arena.allocator(), name, value);
}

pub fn append(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
    return self._params.append(self._arena.allocator(), name, value);
}

pub fn delete(self: *URLSearchParams, name: []const u8, value: ?[]const u8) void {
    self._params.delete(name, value);
}

pub fn keys(self: *URLSearchParams, exec: *const Execution) !*KeyIterator {
    return KeyIterator.init(.{ .list = self }, exec);
}

pub fn values(self: *URLSearchParams, exec: *const Execution) !*ValueIterator {
    return ValueIterator.init(.{ .list = self }, exec);
}

pub fn entries(self: *URLSearchParams, exec: *const Execution) !*EntryIterator {
    return EntryIterator.init(.{ .list = self }, exec);
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

    // the callback can mutate the list
    var i: usize = 0;
    while (i < self._params._entries.items.len) : (i += 1) {
        const entry = self._params._entries.items[i];
        cb.call(void, .{ entry.value.str(), entry.name.str(), self }) catch |err| {
            // this is a non-JS error
            log.warn(.js, "URLSearchParams.forEach", .{ .err = err });
        };
    }
}

pub fn sort(self: *URLSearchParams) void {
    // std.mem.sort is stable (as required by the spec)
    std.mem.sort(KeyValueList.Entry, self._params._entries.items, {}, struct {
        fn cmp(_: void, a: KeyValueList.Entry, b: KeyValueList.Entry) bool {
            return utf16Order(a.name.str(), b.name.str()) == .lt;
        }
    }.cmp);
}

fn utf16Order(a: []const u8, b: []const u8) std.math.Order {
    var ia: usize = 0;
    var ib: usize = 0;
    var pending_a: ?u16 = null;
    var pending_b: ?u16 = null;
    while (true) {
        const ua = nextUtf16Unit(a, &ia, &pending_a) orelse {
            return if (ib < b.len or pending_b != null) .lt else .eq;
        };
        const ub = nextUtf16Unit(b, &ib, &pending_b) orelse return .gt;
        if (ua != ub) {
            return if (ua < ub) .lt else .gt;
        }
    }
}

fn nextUtf16Unit(s: []const u8, i: *usize, pending: *?u16) ?u16 {
    if (pending.*) |unit| {
        pending.* = null;
        return unit;
    }
    if (i.* >= s.len) {
        return null;
    }
    // Invalid UTF-8 (e.g. raw bytes from an unpaired percent-escape) compares
    // as U+FFFD, matching how the bytes surface to JS.
    const seq_len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + seq_len > s.len) {
        i.* = s.len;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.* .. i.* + seq_len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += seq_len;
    if (cp < 0x10000) {
        return @intCast(cp);
    }
    const c = cp - 0x10000;
    pending.* = @intCast(0xDC00 + (c & 0x3FF));
    return @intCast(0xD800 + (c >> 10));
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
            value = comptime .wrap("");
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
        return comptime .wrap("");
    }

    var has_plus = false;
    var unescaped_len = value.len;

    var in_i: usize = 0;
    while (in_i < value.len) {
        const b = value[in_i];
        if (b == '%' and isEscapeTriplet(value, in_i)) {
            in_i += 3;
            unescaped_len -= 2;
        } else {
            has_plus = has_plus or b == '+';
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
        if (b == '%' and isEscapeTriplet(value, in_i)) {
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
    list: *URLSearchParams,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn acquireRef(self: *Iterator) void {
        self.list.acquireRef();
    }

    pub fn releaseRef(self: *Iterator, page: *Page) void {
        self.list.releaseRef(page);
    }

    pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
        const index = self.index;
        const entries_ = self.list._params._entries.items;
        if (index >= entries_.len) {
            return null;
        }
        self.index = index + 1;

        const e = &entries_[index];
        return .{ e.name.str(), e.value.str() };
    }
};

// True when value[i] starts a valid %XX escape
fn isEscapeTriplet(value: []const u8, i: usize) bool {
    return i + 2 < value.len and std.ascii.isHex(value[i + 1]) and std.ascii.isHex(value[i + 2]);
}

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

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
        var buf = std.Io.Writer.Allocating.init(exec.local_arena);
        try self.toString(&buf.writer);
        return buf.written();
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: URLSearchParams" {
    try testing.htmlRunner("net/url_search_params.html", .{});
}
