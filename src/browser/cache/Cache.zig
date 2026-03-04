// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

/// A browser-wide cache for resources across the network.
/// This mostly conforms to RFC9111 with regards to caching behavior.
pub const Cache = @This();

ptr: *anyopaque,
vtable: *const VTable,

const VTable = struct {
    get: *const fn (ptr: *anyopaque, key: []const u8) ?CachedResponse,
    put: *const fn (ptr: *anyopaque, key: []const u8, response: CachedResponse) anyerror!void,
};

pub fn init(ptr: anytype) Cache {
    const T = @TypeOf(ptr.*);

    return .{
        .ptr = ptr,
        .vtable = &.{
            .get = T.get,
            .put = T.put,
        },
    };
}

pub fn get(self: Cache, key: []const u8) ?CachedResponse {
    return self.vtable.get(self.ptr, key);
}

pub fn put(self: Cache, key: []const u8, response: CachedResponse) !void {
    return self.vtable.put(self.ptr, key, response);
}

pub const CachedData = union(enum) {
    file: []const u8,
    bytecode: []const u8,
};

pub const CachedResponse = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),

    // Data that we have cached.
    data: CachedData,

    // RFC 9111 Metadata
    stored_at: i64,
    age_at_store: u64,
    max_age: u64,
};
