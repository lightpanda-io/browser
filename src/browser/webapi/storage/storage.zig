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
const Page = @import("../../Page.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{Lookup};
}

pub const Cookie = @import("Cookie.zig");

pub const Shed = struct {
    _origins: std.StringHashMapUnmanaged(*Bucket) = .empty,

    pub fn deinit(self: *Shed, allocator: Allocator) void {
        var it = self._origins.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.destroy(kv.value_ptr.*);
        }
        self._origins.deinit(allocator);
    }

    pub fn getOrPut(self: *Shed, allocator: Allocator, origin: []const u8) !*Bucket {
        const gop = try self._origins.getOrPut(allocator, origin);
        if (gop.found_existing) {
            return gop.value_ptr.*;
        }

        const bucket = try allocator.create(Bucket);
        errdefer allocator.free(bucket);
        bucket.* = .{};

        gop.key_ptr.* = try allocator.dupe(u8, origin);
        gop.value_ptr.* = bucket;
        return bucket;
    }
};

pub const Bucket = struct { local: Lookup = .{}, session: Lookup = .{} };

pub const Lookup = struct {
    _data: std.StringHashMapUnmanaged([]const u8) = .empty,
    _size: usize = 0,

    const max_size = 5 * 1024 * 1024;

    pub fn getItem(self: *const Lookup, key_: ?[]const u8) ?[]const u8 {
        const k = key_ orelse return null;
        return self._data.get(k);
    }

    pub fn setItem(self: *Lookup, key_: ?[]const u8, value: []const u8, page: *Page) !void {
        const k = key_ orelse return;

        if (self._size + value.len > max_size) {
            return error.QuotaExceeded;
        }
        defer self._size += value.len;

        const key_owned = try page.dupeString(k);
        const value_owned = try page.dupeString(value);

        const gop = try self._data.getOrPut(page.arena, key_owned);
        gop.value_ptr.* = value_owned;
    }

    pub fn removeItem(self: *Lookup, key_: ?[]const u8) void {
        const k = key_ orelse return;
        if (self._data.get(k)) |value| {
            self._size -= value.len;
            _ = self._data.remove(k);
        }
    }

    pub fn clear(self: *Lookup) void {
        self._data.clearRetainingCapacity();
        self._size = 0;
    }

    pub fn key(self: *const Lookup, index: u32) ?[]const u8 {
        var it = self._data.keyIterator();
        var i: u32 = 0;
        while (it.next()) |k| {
            if (i == index) {
                return k.*;
            }
            i += 1;
        }
        return null;
    }

    pub fn getLength(self: *const Lookup) u32 {
        return @intCast(self._data.count());
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Lookup);

        pub const Meta = struct {
            pub const name = "Storage";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.accessor(Lookup.getLength, null, .{});
        pub const getItem = bridge.function(Lookup.getItem, .{});
        pub const setItem = bridge.function(Lookup.setItem, .{ .dom_exception = true });
        pub const removeItem = bridge.function(Lookup.removeItem, .{});
        pub const clear = bridge.function(Lookup.clear, .{});
        pub const key = bridge.function(Lookup.key, .{});
        pub const @"[str]" = bridge.namedIndexed(Lookup.getItem, Lookup.setItem, null, .{ .null_as_undefined = true });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: Storage" {
    try testing.htmlRunner("storage.html", .{});
}
