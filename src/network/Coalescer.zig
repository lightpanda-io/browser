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

const Transfer = @import("../browser/HttpClient.zig").Transfer;

const Coalescer = @This();

allocator: std.mem.Allocator,
pending: std.StringHashMapUnmanaged(std.ArrayList(*Transfer)) = .empty,

pub fn deinit(self: *Coalescer) void {
    var it = self.pending.iterator();
    while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
    self.pending.deinit(self.allocator);
}

pub const JoinResult = enum { first, joined };

pub fn join(
    self: *Coalescer,
    key: []const u8,
    transfer: *Transfer,
    park_tag: Transfer.ParkedBy,
) !JoinResult {
    const entry = try self.pending.getOrPut(self.allocator, key);
    if (!entry.found_existing) {
        entry.value_ptr.* = .empty;
        errdefer _ = self.pending.remove(key);
        try entry.value_ptr.append(self.allocator, transfer);
        transfer.park(park_tag);
        return .first;
    }

    try entry.value_ptr.append(self.allocator, transfer);
    transfer.park(park_tag);
    return .joined;
}

pub fn take(self: *Coalescer, key: []const u8) ?std.ArrayList(*Transfer) {
    const kv = self.pending.fetchRemove(key) orelse return null;
    return kv.value;
}

pub fn peek(self: *Coalescer, key: []const u8) ?[]const *Transfer {
    const list = self.pending.getPtr(key) orelse return null;
    return list.items;
}

pub fn remove(self: *Coalescer, key: []const u8) void {
    var kv = self.pending.fetchRemove(key) orelse return;
    kv.value.deinit(self.allocator);
}
