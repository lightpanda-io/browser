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

pub const cookie = @import("cookie.zig");
pub const Cookie = cookie.Cookie;
pub const CookieJar = cookie.Jar;

pub const Interfaces = .{
    Bottle,
};

// See https://storage.spec.whatwg.org/#model for storage hierarchy.
// A Shed contains map of Shelves. The key is the document's origin.
// A Shelf contains on default Bucket (it could contain many in the future).
// A Bucket contains a local and a session Bottle.
// A Bottle stores a map of strings and is exposed to the JS.

pub const Shed = struct {
    const Map = std.StringHashMapUnmanaged(Shelf);

    alloc: std.mem.Allocator,
    map: Map,

    pub fn init(alloc: std.mem.Allocator) Shed {
        return .{
            .alloc = alloc,
            .map = .{},
        };
    }

    pub fn deinit(self: *Shed) void {
        // loop hover each KV and free the memory.
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.alloc.free(entry.key_ptr.*);
        }
        self.map.deinit(self.alloc);
    }

    pub fn getOrPut(self: *Shed, origin: []const u8) !*Shelf {
        const shelf = self.map.getPtr(origin);
        if (shelf) |s| return s;

        const oorigin = try self.alloc.dupe(u8, origin);
        try self.map.put(self.alloc, oorigin, Shelf.init(self.alloc));
        return self.map.getPtr(origin).?;
    }
};

pub const Shelf = struct {
    bucket: Bucket,

    pub fn init(alloc: std.mem.Allocator) Shelf {
        return .{ .bucket = Bucket.init(alloc) };
    }

    pub fn deinit(self: *Shelf) void {
        self.bucket.deinit();
    }
};

pub const Bucket = struct {
    local: Bottle,
    session: Bottle,

    pub fn init(alloc: std.mem.Allocator) Bucket {
        return .{
            .local = Bottle.init(alloc),
            .session = Bottle.init(alloc),
        };
    }

    pub fn deinit(self: *Bucket) void {
        self.local.deinit();
        self.session.deinit();
    }
};

// https://html.spec.whatwg.org/multipage/webstorage.html#the-storage-interface
pub const Bottle = struct {
    const Map = std.StringHashMapUnmanaged([]const u8);

    // allocator is stored. we don't use the JS env allocator b/c the storage
    // data could exists longer than a js env lifetime.
    alloc: std.mem.Allocator,
    map: Map,

    pub fn init(alloc: std.mem.Allocator) Bottle {
        return .{
            .alloc = alloc,
            .map = .{},
        };
    }

    // loop hover each KV and free the memory.
    fn free(self: *Bottle) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
    }

    pub fn deinit(self: *Bottle) void {
        self.free();
        self.map.deinit(self.alloc);
    }

    pub fn get_length(self: *Bottle) u32 {
        return @intCast(self.map.count());
    }

    pub fn _key(self: *const Bottle, idx: u32) ?[]const u8 {
        if (idx >= self.map.count()) return null;

        var it = self.map.valueIterator();
        var i: u32 = 0;
        while (it.next()) |v| {
            if (i == idx) return v.*;
            i += 1;
        }
        unreachable;
    }

    pub fn _getItem(self: *const Bottle, k: []const u8) ?[]const u8 {
        return self.map.get(k);
    }

    pub fn _setItem(self: *Bottle, k: []const u8, v: []const u8) !void {
        const gop = try self.map.getOrPut(self.alloc, k);

        if (gop.found_existing == false) {
            gop.key_ptr.* = try self.alloc.dupe(u8, k);
            gop.value_ptr.* = try self.alloc.dupe(u8, v);
            return;
        }

        if (std.mem.eql(u8, v, gop.value_ptr.*) == false) {
            self.alloc.free(gop.value_ptr.*);
            gop.value_ptr.* = try self.alloc.dupe(u8, v);
        }

        // > Broadcast this with key, oldValue, and value.
        // https://html.spec.whatwg.org/multipage/webstorage.html#the-storageevent-interface
        //
        // > The storage event of the Window interface fires when a storage
        // > area (localStorage or sessionStorage) has been modified in the
        // > context of another document.
        // https://developer.mozilla.org/en-US/docs/Web/API/Window/storage_event
        //
        // So for now, we won't implement the feature.
    }

    pub fn _removeItem(self: *Bottle, k: []const u8) !void {
        if (self.map.fetchRemove(k)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
        }

        // > Broadcast this with key, oldValue, and null.
        // https://html.spec.whatwg.org/multipage/webstorage.html#the-storageevent-interface
        //
        // > The storage event of the Window interface fires when a storage
        // > area (localStorage or sessionStorage) has been modified in the
        // > context of another document.
        // https://developer.mozilla.org/en-US/docs/Web/API/Window/storage_event
        //
        // So for now, we won't impement the feature.
    }

    pub fn _clear(self: *Bottle) void {
        self.free();
        self.map.clearRetainingCapacity();

        // > Broadcast this with null, null, and null.
        // https://html.spec.whatwg.org/multipage/webstorage.html#the-storageevent-interface
        //
        // > The storage event of the Window interface fires when a storage
        // > area (localStorage or sessionStorage) has been modified in the
        // > context of another document.
        // https://developer.mozilla.org/en-US/docs/Web/API/Window/storage_event
        //
        // So for now, we won't impement the feature.
    }

    pub fn named_get(self: *const Bottle, name: []const u8, _: *bool) ?[]const u8 {
        return self._getItem(name);
    }

    pub fn named_set(self: *Bottle, name: []const u8, value: []const u8, _: *bool) !void {
        try self._setItem(name, value);
    }
};

// Tests
// -----

const testing = @import("../../testing.zig");
test "Browser: Storage.LocalStorage" {
    try testing.htmlRunner("storage/local_storage.html");
}

test "Browser: Storage.Bottle" {
    var bottle = Bottle.init(std.testing.allocator);
    defer bottle.deinit();

    try std.testing.expectEqual(0, bottle.get_length());
    try std.testing.expectEqual(null, bottle._getItem("foo"));

    try bottle._setItem("foo", "bar");
    try std.testing.expectEqualStrings("bar", bottle._getItem("foo").?);

    try bottle._setItem("foo", "other");
    try std.testing.expectEqualStrings("other", bottle._getItem("foo").?);

    try bottle._removeItem("foo");

    try std.testing.expectEqual(0, bottle.get_length());
    try std.testing.expectEqual(null, bottle._getItem("foo"));
}
