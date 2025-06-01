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

pub const jsonToCbor = @import("json_to_cbor.zig").jsonToCbor;
pub const cborToJson = @import("cbor_to_json.zig").cborToJson;

const testing = @import("../../testing.zig");

test "cbor" {
    try testCbor("{\"x\":null}");
    try testCbor("{\"x\":true}");
    try testCbor("{\"x\":false}");
    try testCbor("{\"x\":0}");
    try testCbor("{\"x\":1}");
    try testCbor("{\"x\":-1}");
    try testCbor("{\"x\":4832839283}");
    try testCbor("{\"x\":-998128383}");
    try testCbor("{\"x\":48328.39283}");
    try testCbor("{\"x\":-9981.28383}");
    try testCbor("{\"x\":\"\"}");
    try testCbor("{\"x\":\"over 9000!\"}");

    try testCbor("{\"x\":[]}");
    try testCbor("{\"x\":{}}");
}

fn testCbor(json: []const u8) !void {
    const std = @import("std");

    defer testing.reset();
    const encoded = try jsonToCbor(testing.arena_allocator, json);

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    try cborToJson(encoded, arr.writer(testing.arena_allocator));

    try testing.expectEqual(json, arr.items);
}
