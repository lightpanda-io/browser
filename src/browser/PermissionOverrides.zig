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
const State = @import("webapi/Permissions.zig").State;

const PermissionOverrides = @This();

values: std.StringHashMapUnmanaged(State) = .empty,

pub fn get(self: *const PermissionOverrides, name: []const u8) ?State {
    return self.values.get(name);
}

pub fn count(self: *const PermissionOverrides) usize {
    return self.values.count();
}

pub fn set(self: *PermissionOverrides, allocator: std.mem.Allocator, name: []const u8, state: State) !void {
    const gop = try self.values.getOrPut(allocator, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, name) catch |err| {
            _ = self.values.remove(name);
            return err;
        };
    }
    gop.value_ptr.* = state;
}

pub fn clear(self: *PermissionOverrides, allocator: std.mem.Allocator) void {
    var it = self.values.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    self.values.clearRetainingCapacity();
}

pub fn deinit(self: *PermissionOverrides, allocator: std.mem.Allocator) void {
    self.clear(allocator);
    self.values.deinit(allocator);
    self.* = .{};
}
