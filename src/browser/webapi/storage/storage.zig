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
            kv.value_ptr.*.deinit();
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
        errdefer allocator.destroy(bucket);
        bucket.* = .{};
        bucket.local.setPersistentAllocator(allocator);
        bucket.session.setPersistentAllocator(allocator);

        gop.key_ptr.* = try allocator.dupe(u8, origin);
        gop.value_ptr.* = bucket;
        return bucket;
    }

    pub fn clearLocal(self: *Shed) void {
        var it = self._origins.valueIterator();
        while (it.next()) |bucket| {
            bucket.*.local.clearWithoutMutationNotification();
        }
    }

    pub fn localOriginCount(self: *const Shed) usize {
        var count: usize = 0;
        var it = self._origins.valueIterator();
        while (it.next()) |bucket| {
            if (bucket.*.local.getLength() > 0) {
                count += 1;
            }
        }
        return count;
    }

    pub fn localItemCount(self: *const Shed) usize {
        var count: usize = 0;
        var it = self._origins.valueIterator();
        while (it.next()) |bucket| {
            count += bucket.*.local.getLength();
        }
        return count;
    }
};

pub const Bucket = struct {
    local: Lookup = .{},
    session: Lookup = .{},

    pub fn deinit(self: *Bucket) void {
        self.local.deinit();
        self.session.deinit();
    }
};

pub const Lookup = struct {
    _data: std.StringHashMapUnmanaged([]const u8) = .empty,
    _size: usize = 0,
    _persistent_allocator: ?Allocator = null,
    _mutation_listeners: std.ArrayListUnmanaged(MutationListener) = .{},
    _next_mutation_listener_id: u32 = 1,

    const max_size = 5 * 1024 * 1024;

    pub const Mutation = struct {
        source_ctx: ?*anyopaque = null,
        key: ?[]const u8 = null,
        old_value: ?[]const u8 = null,
        new_value: ?[]const u8 = null,
        url: []const u8 = "",
    };

    const MutationListener = struct {
        id: u32,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque, Mutation) void,
    };

    pub fn getItem(self: *const Lookup, key_: ?[]const u8) ?[]const u8 {
        const k = key_ orelse return null;
        return self._data.get(k);
    }

    pub fn setPersistentAllocator(self: *Lookup, allocator: Allocator) void {
        self._persistent_allocator = allocator;
    }

    pub fn deinit(self: *Lookup) void {
        const allocator = self._persistent_allocator orelse {
            self.* = .{};
            return;
        };

        var it = self._data.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self._data.deinit(allocator);
        self._mutation_listeners.deinit(allocator);
        self.* = .{};
    }

    fn storageAllocator(self: *Lookup, page: *Page) Allocator {
        return self._persistent_allocator orelse page.arena;
    }

    fn setItemWithAllocator(self: *Lookup, allocator: Allocator, key_: ?[]const u8, value: []const u8) !void {
        const k = key_ orelse return;

        const old_value_len = if (self._data.get(k)) |existing| existing.len else 0;
        if (self._size - old_value_len + value.len > max_size) {
            return error.QuotaExceeded;
        }

        const key_owned = try allocator.dupe(u8, k);
        errdefer allocator.free(key_owned);
        const value_owned = try allocator.dupe(u8, value);
        errdefer allocator.free(value_owned);

        const gop = try self._data.getOrPut(allocator, key_owned);
        if (gop.found_existing) {
            if (self._persistent_allocator != null) {
                allocator.free(key_owned);
                allocator.free(gop.value_ptr.*);
            }
            self._size -= gop.value_ptr.*.len;
        }

        gop.value_ptr.* = value_owned;
        self._size += value.len;
    }

    pub fn registerMutationListener(
        self: *Lookup,
        page: *Page,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque, Mutation) void,
    ) !u32 {
        const allocator = self.storageAllocator(page);
        const id = self._next_mutation_listener_id;
        self._next_mutation_listener_id +%= 1;
        try self._mutation_listeners.append(allocator, .{
            .id = id,
            .ctx = ctx,
            .callback = callback,
        });
        return id;
    }

    pub fn unregisterMutationListener(self: *Lookup, id: u32) void {
        for (self._mutation_listeners.items, 0..) |listener, index| {
            if (listener.id == id) {
                _ = self._mutation_listeners.swapRemove(index);
                return;
            }
        }
    }

    fn notifyMutation(self: *Lookup, mutation: Mutation) void {
        for (self._mutation_listeners.items) |listener| {
            listener.callback(listener.ctx, mutation);
        }
    }

    pub fn setItem(self: *Lookup, key_: ?[]const u8, value: []const u8, page: *Page) !void {
        const item_key = key_ orelse return;
        const old_value = self._data.get(item_key);
        if (old_value) |existing| {
            if (std.mem.eql(u8, existing, value)) {
                return;
            }
        }

        const mutation: Mutation = .{
            .source_ctx = @ptrCast(page.window),
            .key = try page.call_arena.dupe(u8, item_key),
            .old_value = if (old_value) |existing| try page.call_arena.dupe(u8, existing) else null,
            .new_value = try page.call_arena.dupe(u8, value),
            .url = try page.call_arena.dupe(u8, page.url),
        };

        try self.setItemWithAllocator(self.storageAllocator(page), key_, value);
        self.notifyMutation(mutation);
    }

    pub fn setOwnedItem(self: *Lookup, allocator: Allocator, key_: ?[]const u8, value: []const u8) !void {
        return self.setItemWithAllocator(self._persistent_allocator orelse allocator, key_, value);
    }

    pub fn removeItem(self: *Lookup, key_: ?[]const u8, page: *Page) void {
        const k = key_ orelse return;
        const old_value = self._data.get(k) orelse return;
        const mutation: Mutation = .{
            .source_ctx = @ptrCast(page.window),
            .key = page.call_arena.dupe(u8, k) catch return,
            .old_value = page.call_arena.dupe(u8, old_value) catch return,
            .new_value = null,
            .url = page.call_arena.dupe(u8, page.url) catch return,
        };
        if (self._persistent_allocator) |allocator| {
            if (self._data.fetchRemove(k)) |removed| {
                self._size -= removed.value.len;
                allocator.free(removed.key);
                allocator.free(removed.value);
            }
        } else if (self._data.get(k)) |value| {
            self._size -= value.len;
            _ = self._data.remove(k);
        }
        self.notifyMutation(mutation);
    }

    pub fn clear(self: *Lookup, page: *Page) void {
        if (self._data.count() == 0) {
            return;
        }
        const mutation: Mutation = .{
            .source_ctx = @ptrCast(page.window),
            .key = null,
            .old_value = null,
            .new_value = null,
            .url = page.call_arena.dupe(u8, page.url) catch return,
        };
        if (self._persistent_allocator) |allocator| {
            var it = self._data.iterator();
            while (it.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                allocator.free(kv.value_ptr.*);
            }
        }
        self._data.clearRetainingCapacity();
        self._size = 0;
        self.notifyMutation(mutation);
    }

    pub fn clearWithoutMutationNotification(self: *Lookup) void {
        if (self._persistent_allocator) |allocator| {
            var it = self._data.iterator();
            while (it.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                allocator.free(kv.value_ptr.*);
            }
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
