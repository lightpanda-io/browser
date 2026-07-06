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
            kv.value_ptr.*.deinit();
            allocator.destroy(kv.value_ptr.*);
        }
        self._origins.deinit(allocator);
    }

    pub fn getOrPut(self: *Shed, allocator: Allocator, origin: []const u8) !*Bucket {
        const gop = try self._origins.getOrPut(allocator, origin);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer std.debug.assert(self._origins.remove(origin));

        const bucket = try allocator.create(Bucket);
        errdefer allocator.destroy(bucket);
        bucket.* = .init(allocator);

        gop.key_ptr.* = try allocator.dupe(u8, origin);
        gop.value_ptr.* = bucket;
        return bucket;
    }
};

pub const Bucket = struct {
    local: Lookup,
    session: Lookup,

    pub fn init(allocator: Allocator) Bucket {
        return .{
            .local = .{ ._allocator = allocator },
            .session = .{ ._allocator = allocator },
        };
    }

    pub fn deinit(self: *Bucket) void {
        self.local.deinit();
        self.session.deinit();
    }
};

pub const Lookup = struct {
    _data: std.StringHashMapUnmanaged([]const u8) = .empty,
    _size: usize = 0,
    _allocator: Allocator,

    const max_size = 5 * 1024 * 1024;

    pub fn deinit(self: *Lookup) void {
        var it = self._data.iterator();
        while (it.next()) |entry| {
            self._allocator.free(entry.key_ptr.*);
            self._allocator.free(entry.value_ptr.*);
        }
        self._data.deinit(self._allocator);
        self._size = 0;
    }

    pub fn getItem(self: *const Lookup, key_: ?[]const u8) ?[]const u8 {
        const k = key_ orelse return null;
        return self._data.get(k);
    }

    pub fn setItem(self: *Lookup, key_: ?[]const u8, value: []const u8) !void {
        const k = key_ orelse return;

        const old_len = if (self._data.get(k)) |old| old.len else 0;
        std.debug.assert(old_len <= self._size);
        if (self._size - old_len + value.len > max_size) {
            return error.QuotaExceeded;
        }

        if (self._data.getPtr(k)) |value_ptr| {
            const value_owned = try self._allocator.dupe(u8, value);
            self._size -= value_ptr.*.len;
            self._allocator.free(value_ptr.*);
            value_ptr.* = value_owned;
            self._size += value.len;
        } else {
            const key_owned = try self._allocator.dupe(u8, k);
            errdefer self._allocator.free(key_owned);
            const value_owned = try self._allocator.dupe(u8, value);
            errdefer self._allocator.free(value_owned);

            try self._data.put(self._allocator, key_owned, value_owned);
            self._size += value.len;
        }
    }

    pub fn removeItem(self: *Lookup, key_: ?[]const u8) void {
        const k = key_ orelse return;
        const kv = self._data.fetchRemove(k) orelse return;
        self._size -= kv.value.len;
        self._allocator.free(kv.key);
        self._allocator.free(kv.value);
    }

    pub fn clear(self: *Lookup) void {
        var it = self._data.iterator();
        while (it.next()) |entry| {
            self._allocator.free(entry.key_ptr.*);
            self._allocator.free(entry.value_ptr.*);
        }
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
        pub const setItem = bridge.function(Lookup.setItem, .{});
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
