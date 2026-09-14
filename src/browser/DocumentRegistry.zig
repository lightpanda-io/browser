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

// Every Document created by the Browser. Allows Node to reference them by
// index (u32).

const std = @import("std");
const lp = @import("lightpanda");

const Document = @import("webapi/Document.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const DocumentRegistry = @This();

allocator: Allocator,
items: std.ArrayList(*Document) = .empty,
free: std.ArrayList(u32) = .empty,

pub fn init(allocator: Allocator) DocumentRegistry {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *DocumentRegistry) void {
    self.items.deinit(self.allocator);
    self.free.deinit(self.allocator);
}

pub fn get(self: *const DocumentRegistry, index: u32) *Document {
    return self.items.items[index];
}

pub fn register(self: *DocumentRegistry, doc: *Document) !u32 {
    if (self.free.pop()) |index| {
        self.items.items[index] = doc;
        return index;
    }
    const index = std.math.cast(u32, self.items.items.len) orelse {
        log.warn(.browser, "document limit", .{ .count = self.items.items.len });
        return error.QuotaExceeded;
    };
    try self.items.append(self.allocator, doc);
    return index;
}

pub fn release(self: *DocumentRegistry, index: u32) void {
    // The slot keeps its stale pointer; nothing resolves it until reused.
    // Failing to record it only loses the slot.
    self.free.append(self.allocator, index) catch {};
}
