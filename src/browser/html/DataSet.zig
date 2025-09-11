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
const parser = @import("../netsurf.zig");
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

const Allocator = std.mem.Allocator;

const DataSet = @This();

element: *parser.Element,

pub fn named_get(self: *const DataSet, name: []const u8, _: *bool, page: *Page) !Env.UndefinedOr([]const u8) {
    const normalized_name = try normalize(page.call_arena, name);
    if (try parser.elementGetAttribute(self.element, normalized_name)) |value| {
        return .{ .value = value };
    }
    return .undefined;
}

pub fn named_set(self: *DataSet, name: []const u8, value: []const u8, _: *bool, page: *Page) !void {
    const normalized_name = try normalize(page.call_arena, name);
    try parser.elementSetAttribute(self.element, normalized_name, value);
}

pub fn named_delete(self: *DataSet, name: []const u8, _: *bool, page: *Page) !void {
    const normalized_name = try normalize(page.call_arena, name);
    try parser.elementRemoveAttribute(self.element, normalized_name);
}

fn normalize(allocator: Allocator, name: []const u8) ![]const u8 {
    var upper_count: usize = 0;
    for (name) |c| {
        if (std.ascii.isUpper(c)) {
            upper_count += 1;
        }
    }
    // for every upper-case letter, we'll probably need a dash before it
    // and we need the 'data-' prefix
    var normalized = try allocator.alloc(u8, name.len + upper_count + 5);

    @memcpy(normalized[0..5], "data-");
    if (upper_count == 0) {
        @memcpy(normalized[5..], name);
        return normalized;
    }

    var pos: usize = 5;
    for (name) |c| {
        if (std.ascii.isUpper(c)) {
            normalized[pos] = '-';
            pos += 1;
            normalized[pos] = c + 32;
        } else {
            normalized[pos] = c;
        }
        pos += 1;
    }
    return normalized;
}

const testing = @import("../../testing.zig");
test "Browser: HTML.DataSet" {
    try testing.htmlRunner("html/dataset.html");
}
