// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SerialLog = struct {
    lines: std.ArrayListUnmanaged([]u8) = .{},

    pub fn init() SerialLog {
        return .{};
    }

    pub fn deinit(self: *SerialLog, allocator: Allocator) void {
        for (self.lines.items) |line| {
            allocator.free(line);
        }
        self.lines.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendLine(self: *SerialLog, allocator: Allocator, line: []const u8) !void {
        const copy = try allocator.dupe(u8, line);
        errdefer allocator.free(copy);
        try self.lines.append(allocator, copy);
    }

    pub fn last(self: *const SerialLog) ?[]const u8 {
        if (self.lines.items.len == 0) {
            return null;
        }
        return self.lines.items[self.lines.items.len - 1];
    }

    pub fn clear(self: *SerialLog, allocator: Allocator) void {
        while (self.lines.items.len > 0) {
            const line = self.lines.pop();
            allocator.free(line);
        }
    }
};

test "serial log keeps the last line" {
    var log = SerialLog.init();
    defer log.deinit(std.testing.allocator);

    try log.appendLine(std.testing.allocator, "first");
    try log.appendLine(std.testing.allocator, "second");
    try std.testing.expectEqualStrings("second", log.last().?);
}
