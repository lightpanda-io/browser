const std = @import("std");

const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

pub const KeyValueList = @This();

_entries: std.ArrayListUnmanaged(Entry) = .empty,

pub const empty: KeyValueList = .{
    ._entries = .empty,
};

pub const Entry = struct {
    name: String,
    value: String,
};

pub fn init() KeyValueList {
    return .{};
}

pub fn ensureTotalCapacity(self: *KeyValueList, allocator: Allocator, n: usize) !void {
    return self._entries.ensureTotalCapacity(allocator, n);
}

pub fn get(self: *const KeyValueList, name: []const u8) ?[]const u8 {
    for (self._entries.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            return entry.value.str();
        }
    }
    return null;
}

pub fn getAll(self: *const KeyValueList, name: []const u8, page: *Page) ![]const []const u8  {
    const arena = page.call_arena;
    var arr: std.ArrayList([]const u8) = .empty;
    for (self._entries.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            try arr.append(arena, entry.value.str());
        }
    }
    return arr.items;
}

pub fn has(self: *const KeyValueList, name: []const u8) bool {
    for (self._entries.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            return true;
        }
    }
    return false;
}

pub fn append(self: *KeyValueList, allocator: Allocator, name: []const u8, value: []const u8) !void {
    try self._entries.append(allocator, .{
        .name = try String.init(allocator, name, .{}),
        .value = try String.init(allocator, value, .{}),
    });
}

pub fn appendAssumeCapacity(self: *KeyValueList, allocator: Allocator, name: []const u8, value: []const u8) !void {
    self._entries.appendAssumeCapacity(.{
        .name = try String.init(allocator, name, .{}),
        .value = try String.init(allocator, value, .{}),
    });
}

pub fn delete(self: *KeyValueList, name: []const u8, value: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry.name.eqlSlice(name)) {
            if (value == null or entry.value.eqlSlice(value.?)) {
                _ = self._entries.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

pub fn set(self: *KeyValueList, allocator: Allocator, name: []const u8, value: []const u8) !void {
    self.delete(name, null);
    try self.append(allocator, name, value);
}

pub fn len(self: *const KeyValueList) usize {
    return self._entries.items.len;
}

pub fn items(self: *const KeyValueList) []const Entry {
    return self._entries.items;
}

pub const Iterator = struct {
    index: u32 = 0,
    kv: *KeyValueList,

    // Why? Because whenever an Iterator is created, we need to increment the
    // RC of what it's iterating. And when the iterator is destroyed, we need
    // to decrement it. The generic iterator which will wrap this handles that
    // by using this "list" field. Most things that use the GenericIterator can
    // just set `list: *ZigCollection`, and everything will work. But KeyValueList
    // is being composed by various types, so it can't reference those types.
    // Using *anyopaque here is "dangerous", in that it requires the composer
    // to pass the right value, which normally would be itself (`*Self`), but
    // only because (as of now) everyting that uses KeyValueList has no prototype
    list: *anyopaque,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Page) ?Iterator.Entry {
        const index = self.index;
        const entries = self.kv._entries.items;
        if (index >= entries.len) {
            return null;
        }
        self.index = index + 1;

        const e = &entries[index];
        return .{ e.name.str(), e.value.str() };
    }
};

pub fn iterator(self: *const KeyValueList) Iterator {
    return .{ .list = self };
}

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);
