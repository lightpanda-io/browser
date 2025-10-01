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

const js = @import("../js/js.zig");

// https://encoding.spec.whatwg.org/#interface-textencoder
const TextEncoder = @This();

pub fn constructor() !TextEncoder {
    return .{};
}

pub fn get_encoding(_: *const TextEncoder) []const u8 {
    return "utf-8";
}

pub fn _encode(_: *const TextEncoder, v: []const u8) !js.TypedArray(u8) {
    // Ensure the input is a valid utf-8
    // It seems chrome accepts invalid utf-8 sequence.
    //
    if (!std.unicode.utf8ValidateSlice(v)) {
        return error.InvalidUtf8;
    }

    return .{ .values = v };
}

const testing = @import("../../testing.zig");
test "Browser: Encoding.TextEncoder" {
    try testing.htmlRunner("encoding/encoder.html");
}
