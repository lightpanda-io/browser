const std = @import("std");
const js = @import("../../js/js.zig");

const log = @import("../../../log.zig");
const String = @import("../../../string.zig").String;
const Allocator = std.mem.Allocator;

const Page = @import("../../Page.zig");
const GenericIterator = @import("../collections/iterator.zig").Entry;

pub fn registerTypes() []const type {
    return &.{
        URLSearchParams,
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

const URLSearchParams = @This();

_arena: Allocator,
_params: Entry.List,

pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

const InitOpts = union(enum) {
    query_string: []const u8,
    // @ZIGMOD: Array
    // @ZIGMOD: Object
};
pub fn init(opts_: ?InitOpts, page: *Page) !*URLSearchParams {
    const arena = page.arena;
    const params: Entry.List = blk: {
        const opts = opts_ orelse break :blk .empty;
        break :blk switch (opts) {
            .query_string => |str| try paramsFromString(arena, str, &page.buf),
        };
    };

    return page._factory.create(URLSearchParams{
        ._arena = arena,
        ._params = params,
    });
}

pub fn getSize(self: *const URLSearchParams) usize {
    return self._params.items.len;
}

pub fn get(self: *const URLSearchParams, name: []const u8) ?[]const u8 {
    const entry = self.getEntry(name) orelse return null;
    return entry.value.str();
}

pub fn getAll(self: *const URLSearchParams, name: []const u8, page: *Page) ![]const []const u8 {
    const arena = page.call_arena;
    var arr: std.ArrayList([]const u8) = .empty;
    for (self._params.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            try arr.append(arena, entry.value.str());
        }
    }
    return arr.items;
}

pub fn has(self: *const URLSearchParams, name: []const u8) bool {
    return self.getEntry(name) != null;
}

pub fn set(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
    self.delete(name, null);
    return self.append(name, value);
}

pub fn append(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
    const arena = self._arena;
    return self._params.append(arena, .{
        .name = try String.init(arena, name, .{}),
        .value = try String.init(arena, value, .{}),
    });
}

pub fn delete(self: *URLSearchParams, name: []const u8, value: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._params.items.len) {
        const entry = self._params.items[i];
        if (entry.name.eqlSlice(name)) {
            if (value == null or entry.value.eqlSlice(value.?)) {
                _ = self._params.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

pub fn keys(self: *const URLSearchParams, page: *Page) !*KeyIterator {
    return .init(.{ .list = self }, page);
}

pub fn values(self: *const URLSearchParams, page: *Page) !*ValueIterator {
    return .init(.{ .list = self }, page);
}

pub fn entries(self: *const URLSearchParams, page: *Page) !*EntryIterator {
    return .init(.{ .list = self }, page);
}

pub fn toString(self: *const URLSearchParams, writer: *std.Io.Writer) !void {
    const items = self._params.items;
    if (items.len == 0) {
        return;
    }

    try items[0].toString(writer);
    for (items[1..]) |entry| {
        try writer.writeByte('&');
        try entry.toString(writer);
    }
}

pub fn format(self: *const URLSearchParams, writer: *std.Io.Writer) !void {
    return self.toString(writer);
}

pub fn forEach(self: *URLSearchParams, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._params.items) |entry| {
        cb.call(void, .{ entry.value.str(), entry.name.str(), self }) catch |err| {
            // this is a non-JS error
            log.warn(.js, "URLSearchParams.forEach", .{ .err = err });
        };
    }
}

pub fn sort(self: *URLSearchParams) void {
    std.mem.sort(Entry, self._params.items, {}, entryLessThan);
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name.str(), b.name.str()) == .lt;
}

fn getEntry(self: *const URLSearchParams, name: []const u8) ?*Entry {
    for (self._params.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            return entry;
        }
    }
    return null;
}

fn paramsFromString(arena: Allocator, input_: []const u8, buf: []u8) !Entry.List {
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

    var params: Entry.List = .empty;

    var it = std.mem.splitScalar(u8, input, '&');
    while (it.next()) |entry| {
        var name: String = undefined;
        var value: String = undefined;
        if (std.mem.indexOfScalarPos(u8, entry, 0, '=')) |idx| {
            name = try unescape(arena, entry[0..idx], buf);
            value = try unescape(arena, entry[idx + 1 ..], buf);
        } else {
            name = try unescape(arena, entry, buf);
            value = String.init(undefined, "", .{}) catch unreachable;
        }

        try params.append(arena, .{
            .name = name,
            .value = value,
        });
    }

    return params;
}

const Entry = struct {
    name: String,
    value: String,

    const List = std.ArrayListUnmanaged(Entry);

    pub fn toString(self: *const Entry, writer: *std.Io.Writer) !void {
        try escape(self.name.str(), writer);
        try writer.writeByte('=');
        try escape(self.value.str(), writer);
    }
};

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

fn escape(input: []const u8, writer: *std.Io.Writer) !void {
    for (input) |c| {
        if (isUnreserved(c)) {
            try writer.writeByte(c);
        } else {
            try writer.print("%{X:0>2}", .{c});
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

pub const Iterator = struct {
    index: u32 = 0,
    list: *const URLSearchParams,

    const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *Page) !?Iterator.Entry {
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
        pub var class_index: u16 = 0;
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
    fn _toString(self: *const URLSearchParams, page: *Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.toString(&buf.writer);
        return buf.written();
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: URLSearchParams" {
    try testing.htmlRunner("net/url_search_params.html", .{});
}
