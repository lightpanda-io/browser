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
const Page = @import("../page.zig").Page;
const Allocator = std.mem.Allocator;

const DataSet = @This();

attributes: std.StringHashMapUnmanaged([]const u8),

pub const empty: DataSet = .{
    .attributes = .empty,
};

const GetResult = union(enum) {
    value: []const u8,
    undefined: void,
};
pub fn named_get(self: *const DataSet, name: []const u8, _: *bool) GetResult {
    if (self.attributes.get(name)) |value| {
        return .{ .value = value };
    }
    return .{ .undefined = {} };
}

pub fn named_set(self: *DataSet, name: []const u8, value: []const u8, _: *bool, page: *Page) !void {
    const arena = page.arena;
    const gop = try self.attributes.getOrPut(arena, name);
    errdefer _ = self.attributes.remove(name);

    if (!gop.found_existing) {
        gop.key_ptr.* = try arena.dupe(u8, name);
    }
    gop.value_ptr.* = try arena.dupe(u8, value);
}

pub fn named_delete(self: *DataSet, name: []const u8, _: *bool) void {
    _ = self.attributes.remove(name);
}

pub fn normalizeName(allocator: Allocator, name: []const u8) ![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, name, "data-"));
    var owned = try allocator.alloc(u8, name.len - 5);

    var pos: usize = 0;
    var capitalize = false;
    for (name[5..]) |c| {
        if (c == '-') {
            capitalize = true;
            continue;
        }

        if (capitalize) {
            capitalize = false;
            owned[pos] = std.ascii.toUpper(c);
        } else {
            owned[pos] = c;
        }
        pos += 1;
    }
    return owned[0..pos];
}

const testing = @import("../../testing.zig");
test "Browser.HTML.DataSet" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html = "" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let el1 = document.createElement('div')", null },
        .{ "el1.dataset.x", "undefined" },
        .{ "el1.dataset.x = '123'", "123" },
        .{ "delete el1.dataset.x", "true" },
        .{ "el1.dataset.x", "undefined" },
        .{ "delete el1.dataset.other", "true" }, // yes, this is right
    }, .{});
}
